//! Reading and writing chunk files. See the crate docs for the format.

use std::fs::{File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::FileExt;
use std::path::{Path, PathBuf};

use chacha20poly1305::aead::{Aead, KeyInit, Payload};
use chacha20poly1305::{ChaCha20Poly1305, Key, Nonce};

use crate::{MasterKey, Result, VaultError};

const MAGIC: &[u8; 8] = b"ELDCHUNK";
const VERSION: u16 = 1;
/// magic, version, reserved, chunk ID, and header length.
const PREFIX_LEN: usize = 8 + 2 + 2 + 16 + 4;
/// wall_ms, mono_ns, flags, and meta_len.
const FIXED_PLAINTEXT_LEN: usize = 8 + 8 + 4 + 4;
const TAG_LEN: usize = 16;
/// The header's nonce. Record sequence numbers can't reach it.
const HEADER_NONCE: u64 = u64::MAX;

/// The largest encrypted record accepted. It bounds how much recovery will try
/// to read from a corrupt length field.
pub const MAX_RECORD_LEN: u32 = 64 * 1024 * 1024;

/// Record flags.
pub mod flags {
    /// Decoding can start at this sample.
    pub const SYNC: u32 = 1 << 0;
}

/// A chunk's fixed properties.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ChunkHeader {
    pub id: [u8; 16],
    pub display_uuid: [u8; 16],
    pub width: u32,
    pub height: u32,
    /// The codec's parameter sets (`hvcC`), needed to decode any sample.
    pub parameter_sets: Vec<u8>,
}

/// A record to append, borrowing its data.
#[derive(Clone, Copy, Debug)]
pub struct RecordRef<'a> {
    pub wall_ms: i64,
    pub mono_ns: u64,
    pub flags: u32,
    pub meta: &'a [u8],
    pub sample: &'a [u8],
}

/// A decoded record.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Record {
    pub wall_ms: i64,
    pub mono_ns: u64,
    pub flags: u32,
    pub meta: Vec<u8>,
    pub sample: Vec<u8>,
}

impl Record {
    pub fn is_sync(&self) -> bool {
        self.flags & flags::SYNC != 0
    }
}

/// Where an appended record landed. `offset` and `len` cover the whole record,
/// including its length prefix.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Appended {
    pub seq: u64,
    pub offset: u64,
    pub len: u32,
}

fn cipher(master: &MasterKey, chunk_id: &[u8; 16]) -> ChaCha20Poly1305 {
    ChaCha20Poly1305::new(&Key::from(master.chunk_key(chunk_id)))
}

fn nonce(seq: u64) -> Nonce {
    let mut bytes = [0u8; 12];
    bytes[4..].copy_from_slice(&seq.to_le_bytes());
    Nonce::from(bytes)
}

fn record_aad(chunk_id: &[u8; 16], seq: u64) -> [u8; 24] {
    let mut aad = [0u8; 24];
    aad[..16].copy_from_slice(chunk_id);
    aad[16..].copy_from_slice(&seq.to_le_bytes());
    aad
}

/// Asks the drive to flush its cache. A plain `fsync` on macOS doesn't.
fn full_sync(file: &File) -> std::io::Result<()> {
    // SAFETY: the descriptor is valid for the borrow of `file`.
    let rc = unsafe { libc::fcntl(file.as_raw_fd(), libc::F_FULLFSYNC) };
    if rc == 0 {
        return Ok(());
    }
    // Some filesystems don't support it. Fall back rather than fail.
    file.sync_all()
}

/// Appends records to a new chunk file.
#[derive(Debug)]
pub struct ChunkWriter {
    file: File,
    path: PathBuf,
    header: ChunkHeader,
    cipher: ChaCha20Poly1305,
    next_seq: u64,
    len: u64,
    dirty: bool,
    failed: bool,
}

impl ChunkWriter {
    /// Creates a chunk at `path`, which must not exist.
    ///
    /// The header and its directory entry are synced before this returns, so a
    /// chunk the database knows about can't vanish in a power cut.
    pub fn create(path: &Path, master: &MasterKey, header: ChunkHeader) -> Result<Self> {
        let cipher = cipher(master, &header.id);

        let mut plaintext = Vec::with_capacity(24 + header.parameter_sets.len());
        plaintext.extend_from_slice(&header.display_uuid);
        plaintext.extend_from_slice(&header.width.to_le_bytes());
        plaintext.extend_from_slice(&header.height.to_le_bytes());
        plaintext.extend_from_slice(&header.parameter_sets);

        let ciphertext_len = plaintext.len() + TAG_LEN;
        let mut prefix = [0u8; PREFIX_LEN];
        prefix[..8].copy_from_slice(MAGIC);
        prefix[8..10].copy_from_slice(&VERSION.to_le_bytes());
        prefix[12..28].copy_from_slice(&header.id);
        let ciphertext_len_field =
            u32::try_from(ciphertext_len).map_err(|_| VaultError::RecordTooLarge(ciphertext_len))?;
        prefix[28..32].copy_from_slice(&ciphertext_len_field.to_le_bytes());

        let ciphertext = cipher
            .encrypt(&nonce(HEADER_NONCE), Payload { msg: &plaintext, aad: &prefix })
            .map_err(|_| VaultError::Authentication)?;

        let mut buffer = Vec::with_capacity(PREFIX_LEN + ciphertext.len());
        buffer.extend_from_slice(&prefix);
        buffer.extend_from_slice(&ciphertext);

        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let mut file = OpenOptions::new().write(true).create_new(true).open(path)?;
        file.write_all(&buffer)?;
        full_sync(&file)?;
        if let Some(parent) = path.parent() {
            full_sync(&File::open(parent)?)?;
        }

        Ok(Self {
            file,
            path: path.to_owned(),
            header,
            cipher,
            next_seq: 0,
            len: buffer.len() as u64,
            dirty: false,
            failed: false,
        })
    }

    pub fn header(&self) -> &ChunkHeader {
        &self.header
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Bytes written so far, including the header.
    pub fn len(&self) -> u64 {
        self.len
    }

    /// Whether no records have been written.
    pub fn is_empty(&self) -> bool {
        self.next_seq == 0
    }

    pub fn is_dirty(&self) -> bool {
        self.dirty
    }

    /// Appends a record. It survives SIGKILL once this returns, and survives
    /// power loss after the next [`sync`](Self::sync).
    ///
    /// After an I/O error the chunk accepts nothing more: retrying would reuse a
    /// nonce on ciphertext that may have reached the disk. Open a new chunk.
    pub fn append(&mut self, record: RecordRef<'_>) -> Result<Appended> {
        if self.failed {
            return Err(VaultError::WriterFailed);
        }
        let plaintext_len = FIXED_PLAINTEXT_LEN + record.meta.len() + record.sample.len();
        if plaintext_len + TAG_LEN > MAX_RECORD_LEN as usize {
            return Err(VaultError::RecordTooLarge(plaintext_len));
        }
        let meta_len = u32::try_from(record.meta.len())
            .map_err(|_| VaultError::RecordTooLarge(record.meta.len()))?;

        let mut plaintext = Vec::with_capacity(plaintext_len);
        plaintext.extend_from_slice(&record.wall_ms.to_le_bytes());
        plaintext.extend_from_slice(&record.mono_ns.to_le_bytes());
        plaintext.extend_from_slice(&record.flags.to_le_bytes());
        plaintext.extend_from_slice(&meta_len.to_le_bytes());
        plaintext.extend_from_slice(record.meta);
        plaintext.extend_from_slice(record.sample);

        let seq = self.next_seq;
        let aad = record_aad(&self.header.id, seq);
        let ciphertext = self
            .cipher
            .encrypt(&nonce(seq), Payload { msg: &plaintext, aad: &aad })
            .map_err(|_| VaultError::Authentication)?;

        let mut buffer = Vec::with_capacity(4 + ciphertext.len());
        buffer.extend_from_slice(&(ciphertext.len() as u32).to_le_bytes());
        buffer.extend_from_slice(&ciphertext);

        if let Err(error) = self.file.write_all(&buffer) {
            self.failed = true;
            // Best effort: remove any partial record. Recovery handles it if
            // this fails or we die first.
            let _ = self.file.set_len(self.len);
            return Err(error.into());
        }

        let appended = Appended { seq, offset: self.len, len: buffer.len() as u32 };
        self.next_seq += 1;
        self.len += buffer.len() as u64;
        self.dirty = true;
        Ok(appended)
    }

    /// Flushes everything to the drive.
    pub fn sync(&mut self) -> Result<()> {
        if self.dirty {
            full_sync(&self.file)?;
            self.dirty = false;
        }
        Ok(())
    }

    /// Syncs and closes the chunk. It's never written again.
    pub fn seal(mut self) -> Result<()> {
        self.sync()
    }
}

/// Reads records from a chunk file.
#[derive(Debug)]
pub struct ChunkReader {
    file: File,
    header: ChunkHeader,
    cipher: ChaCha20Poly1305,
    first_record: u64,
    file_len: u64,
}

impl ChunkReader {
    pub fn open(path: &Path, master: &MasterKey) -> Result<Self> {
        let mut file = File::open(path)?;
        let file_len = file.metadata()?.len();

        let mut prefix = [0u8; PREFIX_LEN];
        file.read_exact(&mut prefix).map_err(|_| VaultError::NotAChunk)?;
        if &prefix[..8] != MAGIC {
            return Err(VaultError::NotAChunk);
        }
        let version = u16::from_le_bytes([prefix[8], prefix[9]]);
        if version != VERSION {
            return Err(VaultError::UnsupportedVersion(version));
        }
        let mut id = [0u8; 16];
        id.copy_from_slice(&prefix[12..28]);
        let header_len = u32::from_le_bytes([prefix[28], prefix[29], prefix[30], prefix[31]]);
        if header_len > MAX_RECORD_LEN {
            return Err(VaultError::Malformed);
        }

        let mut ciphertext = vec![0u8; header_len as usize];
        file.read_exact(&mut ciphertext).map_err(|_| VaultError::Malformed)?;
        let cipher = cipher(master, &id);
        let plaintext = cipher
            .decrypt(&nonce(HEADER_NONCE), Payload { msg: &ciphertext, aad: &prefix })
            .map_err(|_| VaultError::Authentication)?;
        if plaintext.len() < 24 {
            return Err(VaultError::Malformed);
        }
        let mut display_uuid = [0u8; 16];
        display_uuid.copy_from_slice(&plaintext[..16]);
        let width = u32::from_le_bytes([plaintext[16], plaintext[17], plaintext[18], plaintext[19]]);
        let height = u32::from_le_bytes([plaintext[20], plaintext[21], plaintext[22], plaintext[23]]);

        Ok(Self {
            first_record: file.seek(SeekFrom::Current(0))?,
            file,
            header: ChunkHeader {
                id,
                display_uuid,
                width,
                height,
                parameter_sets: plaintext[24..].to_vec(),
            },
            cipher,
            file_len,
        })
    }

    pub fn header(&self) -> &ChunkHeader {
        &self.header
    }

    /// Where the first record starts.
    pub fn first_record_offset(&self) -> u64 {
        self.first_record
    }

    /// Reads one record, given its location from the database.
    pub fn read_at(&self, seq: u64, offset: u64, len: u32) -> Result<Record> {
        if len < 4 + TAG_LEN as u32 || len > MAX_RECORD_LEN + 4 {
            return Err(VaultError::Malformed);
        }
        let mut buffer = vec![0u8; len as usize];
        self.file.read_exact_at(&mut buffer, offset)?;
        let ct_len = u32::from_le_bytes([buffer[0], buffer[1], buffer[2], buffer[3]]);
        if ct_len != len - 4 {
            return Err(VaultError::Malformed);
        }
        self.decrypt_record(seq, &buffer[4..])
    }

    fn decrypt_record(&self, seq: u64, ciphertext: &[u8]) -> Result<Record> {
        let aad = record_aad(&self.header.id, seq);
        let plaintext = self
            .cipher
            .decrypt(&nonce(seq), Payload { msg: ciphertext, aad: &aad })
            .map_err(|_| VaultError::Authentication)?;
        parse_record(&plaintext)
    }

    /// Reads records from `start`, stopping at the end of the file or at the
    /// first record that doesn't authenticate.
    pub fn scan(&self, start: ScanStart) -> Scan<'_> {
        let (seq, offset) = match start {
            ScanStart::Beginning => (0, self.first_record),
            ScanStart::At { seq, offset } => (seq, offset),
        };
        Scan { reader: self, seq, offset, torn: false }
    }
}

pub use self::scan::{Scan, ScanStart, ScannedRecord};

mod scan {
    use super::*;

    /// Where a scan begins.
    #[derive(Clone, Copy, Debug)]
    pub enum ScanStart {
        Beginning,
        /// Resume at a known record.
        At { seq: u64, offset: u64 },
    }

    /// A record found by a scan, and where it is.
    #[derive(Clone, Debug)]
    pub struct ScannedRecord {
        pub location: Appended,
        pub record: Record,
    }

    /// An iterator over a chunk's valid records.
    #[derive(Debug)]
    pub struct Scan<'a> {
        pub(super) reader: &'a ChunkReader,
        pub(super) seq: u64,
        pub(super) offset: u64,
        pub(super) torn: bool,
    }

    impl Scan<'_> {
        /// The first byte past the last valid record.
        pub fn valid_len(&self) -> u64 {
            self.offset
        }

        /// How many records precede [`valid_len`](Self::valid_len).
        pub fn next_seq(&self) -> u64 {
            self.seq
        }

        /// Whether the scan stopped at damaged or incomplete data rather than a
        /// clean end of file.
        pub fn is_torn(&self) -> bool {
            self.torn
        }
    }

    impl Iterator for Scan<'_> {
        type Item = ScannedRecord;

        fn next(&mut self) -> Option<ScannedRecord> {
            if self.torn || self.offset >= self.reader.file_len {
                return None;
            }
            let remaining = self.reader.file_len - self.offset;
            let mut length = [0u8; 4];
            if remaining < 4 || self.reader.file.read_exact_at(&mut length, self.offset).is_err() {
                self.torn = true;
                return None;
            }
            let ct_len = u32::from_le_bytes(length);
            let total = 4 + u64::from(ct_len);
            if ct_len > MAX_RECORD_LEN || total > remaining {
                self.torn = true;
                return None;
            }
            let mut ciphertext = vec![0u8; ct_len as usize];
            if self.reader.file.read_exact_at(&mut ciphertext, self.offset + 4).is_err() {
                self.torn = true;
                return None;
            }
            let Ok(record) = self.reader.decrypt_record(self.seq, &ciphertext) else {
                self.torn = true;
                return None;
            };
            let location = Appended { seq: self.seq, offset: self.offset, len: total as u32 };
            self.seq += 1;
            self.offset += total;
            Some(ScannedRecord { location, record })
        }
    }
}

fn parse_record(plaintext: &[u8]) -> Result<Record> {
    if plaintext.len() < FIXED_PLAINTEXT_LEN {
        return Err(VaultError::Malformed);
    }
    let (fixed, rest) = plaintext.split_at(FIXED_PLAINTEXT_LEN);
    let wall_ms = i64::from_le_bytes(fixed[..8].try_into().map_err(|_| VaultError::Malformed)?);
    let mono_ns = u64::from_le_bytes(fixed[8..16].try_into().map_err(|_| VaultError::Malformed)?);
    let flags = u32::from_le_bytes(fixed[16..20].try_into().map_err(|_| VaultError::Malformed)?);
    let meta_len =
        u32::from_le_bytes(fixed[20..24].try_into().map_err(|_| VaultError::Malformed)?) as usize;
    if meta_len > rest.len() {
        return Err(VaultError::Malformed);
    }
    let (meta, sample) = rest.split_at(meta_len);
    Ok(Record { wall_ms, mono_ns, flags, meta: meta.to_vec(), sample: sample.to_vec() })
}

/// Truncates a chunk to `valid_len`, removing a torn tail left by a crash.
pub fn recover_tail(path: &Path, valid_len: u64) -> Result<()> {
    let file = OpenOptions::new().write(true).open(path)?;
    if file.metadata()?.len() > valid_len {
        file.set_len(valid_len)?;
        full_sync(&file)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;
    use tempfile::TempDir;

    fn master() -> MasterKey {
        MasterKey::from_bytes([3; 32])
    }

    fn header() -> ChunkHeader {
        ChunkHeader {
            id: [5; 16],
            display_uuid: [6; 16],
            width: 3024,
            height: 1964,
            parameter_sets: b"parameter sets".to_vec(),
        }
    }

    fn record(n: u8, sample: &[u8]) -> RecordRef<'_> {
        RecordRef {
            wall_ms: i64::from(n) * 2000,
            mono_ns: u64::from(n),
            flags: if n % 30 == 0 { flags::SYNC } else { 0 },
            meta: b"meta",
            sample,
        }
    }

    fn write_chunk(path: &Path, count: u8) -> Vec<Appended> {
        let mut writer = ChunkWriter::create(path, &master(), header()).unwrap();
        let sample = vec![0xAA; 1000];
        let locations = (0..count).map(|n| writer.append(record(n, &sample)).unwrap()).collect();
        writer.seal().unwrap();
        locations
    }

    #[test]
    fn round_trips_header_and_records() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("chunk");
        let locations = write_chunk(&path, 3);

        let reader = ChunkReader::open(&path, &master()).unwrap();
        assert_eq!(reader.header(), &header());
        for (n, location) in locations.iter().enumerate() {
            let read = reader.read_at(location.seq, location.offset, location.len).unwrap();
            assert_eq!(read.wall_ms, n as i64 * 2000);
            assert_eq!(read.meta, b"meta");
            assert_eq!(read.sample, vec![0xAA; 1000]);
        }
    }

    #[test]
    fn nothing_recognisable_is_stored_in_plaintext() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("chunk");
        let mut writer = ChunkWriter::create(&path, &master(), header()).unwrap();
        writer
            .append(RecordRef {
                wall_ms: 0,
                mono_ns: 0,
                flags: 0,
                meta: b"window-title-secret",
                sample: b"sample-secret",
            })
            .unwrap();
        writer.seal().unwrap();

        let bytes = std::fs::read(&path).unwrap();
        for needle in [&b"window-title-secret"[..], b"sample-secret", b"parameter sets"] {
            assert!(!bytes.windows(needle.len()).any(|w| w == needle));
        }
    }

    #[test]
    fn a_wrong_key_is_rejected_at_open() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("chunk");
        write_chunk(&path, 1);
        let wrong = MasterKey::from_bytes([4; 32]);
        assert!(matches!(ChunkReader::open(&path, &wrong), Err(VaultError::Authentication)));
    }

    #[test]
    fn create_refuses_to_reopen_an_existing_chunk() {
        // Reopening would repeat nonces.
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("chunk");
        write_chunk(&path, 1);
        assert!(ChunkWriter::create(&path, &master(), header()).is_err());
    }

    #[test]
    fn a_record_read_with_the_wrong_seq_fails() {
        // The sequence number is authenticated, so records can't be swapped.
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("chunk");
        let locations = write_chunk(&path, 2);
        let reader = ChunkReader::open(&path, &master()).unwrap();
        let first = locations[0];
        assert!(matches!(
            reader.read_at(1, first.offset, first.len),
            Err(VaultError::Authentication)
        ));
    }

    #[test]
    fn records_from_another_chunk_are_rejected() {
        let dir = TempDir::new().unwrap();
        let (a, b) = (dir.path().join("a"), dir.path().join("b"));
        let locations = write_chunk(&a, 1);
        let mut other = header();
        other.id = [9; 16];
        ChunkWriter::create(&b, &master(), other).unwrap().seal().unwrap();
        // Splice chunk A's record onto chunk B.
        let record = &std::fs::read(&a).unwrap()[locations[0].offset as usize..];
        let mut file = OpenOptions::new().append(true).open(&b).unwrap();
        file.write_all(record).unwrap();
        let reader = ChunkReader::open(&b, &master()).unwrap();
        assert_eq!(reader.scan(ScanStart::Beginning).count(), 0);
    }

    #[test]
    fn scanning_a_clean_file_finds_every_record() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("chunk");
        let locations = write_chunk(&path, 5);
        let reader = ChunkReader::open(&path, &master()).unwrap();
        let mut scan = reader.scan(ScanStart::Beginning);
        let found: Vec<_> = scan.by_ref().map(|r| r.location).collect();
        assert_eq!(found, locations);
        assert!(!scan.is_torn());
        assert_eq!(scan.next_seq(), 5);
    }

    #[test]
    fn scanning_can_resume_from_a_known_record() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("chunk");
        let locations = write_chunk(&path, 5);
        let reader = ChunkReader::open(&path, &master()).unwrap();
        let start = ScanStart::At { seq: 3, offset: locations[3].offset };
        let found: Vec<_> = reader.scan(start).map(|r| r.location.seq).collect();
        assert_eq!(found, [3, 4]);
    }

    #[test]
    fn an_empty_chunk_scans_cleanly() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("chunk");
        write_chunk(&path, 0);
        let reader = ChunkReader::open(&path, &master()).unwrap();
        let mut scan = reader.scan(ScanStart::Beginning);
        assert!(scan.next().is_none());
        assert!(!scan.is_torn());
    }

    #[test]
    fn a_failed_writer_refuses_more_records() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("chunk");
        let mut writer = ChunkWriter::create(&path, &master(), header()).unwrap();
        writer.failed = true;
        assert!(matches!(writer.append(record(0, b"x")), Err(VaultError::WriterFailed)));
    }

    #[test]
    fn oversized_records_are_rejected_without_writing() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("chunk");
        let mut writer = ChunkWriter::create(&path, &master(), header()).unwrap();
        let huge = vec![0u8; MAX_RECORD_LEN as usize + 1];
        let before = writer.len();
        assert!(matches!(writer.append(record(0, &huge)), Err(VaultError::RecordTooLarge(_))));
        assert_eq!(writer.len(), before);
        writer.append(record(0, b"ok")).unwrap();
    }

    proptest! {
        /// Whatever a crash does to the end of a file, a scan returns an intact
        /// prefix, and truncating there leaves a clean chunk.
        #[test]
        fn any_truncation_or_corruption_leaves_a_valid_prefix(
            count in 1u8..12,
            cut in 0.0f64..1.0,
            flip in proptest::option::of((0.0f64..1.0, 1u8..=255)),
        ) {
            let dir = TempDir::new().unwrap();
            let path = dir.path().join("chunk");
            let locations = write_chunk(&path, count);
            let header_end = locations[0].offset;
            let total = std::fs::metadata(&path).unwrap().len();

            let mut bytes = std::fs::read(&path).unwrap();
            if let Some((position, mask)) = flip {
                let span = total - header_end;
                let index = header_end + ((span - 1) as f64 * position) as u64;
                bytes[index as usize] ^= mask;
            }
            let keep = header_end + ((total - header_end) as f64 * cut) as u64;
            bytes.truncate(keep as usize);
            std::fs::write(&path, &bytes).unwrap();

            let reader = ChunkReader::open(&path, &master()).unwrap();
            let mut scan = reader.scan(ScanStart::Beginning);
            let recovered: Vec<_> = scan.by_ref().collect();
            for (n, found) in recovered.iter().enumerate() {
                prop_assert_eq!(found.location, locations[n]);
                prop_assert_eq!(found.record.sample.len(), 1000);
            }

            let valid_len = scan.valid_len();
            drop(scan);
            drop(reader);
            recover_tail(&path, valid_len).unwrap();
            let reader = ChunkReader::open(&path, &master()).unwrap();
            let mut clean = reader.scan(ScanStart::Beginning);
            prop_assert_eq!(clean.by_ref().count(), recovered.len());
            prop_assert!(!clean.is_torn());
        }
    }
}
