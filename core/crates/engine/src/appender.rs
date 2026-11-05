//! The appender thread: writes samples to chunk files.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::Ordering;
use std::thread::JoinHandle;
use std::time::Instant;

use crossbeam_channel::{Receiver, RecvTimeoutError, Sender};
use remind_store::{ChunkInfo, LoggedFrame, segment};
use remind_vault::{ChunkHeader, ChunkWriter, MasterKey, RecordRef, flags};

use crate::writer::WriterMessage;
use crate::{EngineConfig, Sample, Shared};

pub(crate) enum AppendRequest {
    Sample(Sample),
    SealAll(Sender<()>),
}

/// The path of a chunk relative to the vault root. It's sharded by ID rather
/// than by date, so the directory layout doesn't reveal when you were active.
pub(crate) fn chunk_relative_path(id: &[u8; 16]) -> String {
    let hex: String = id.iter().map(|b| format!("{b:02x}")).collect();
    format!("chunks/{}/{hex}.chunk", &hex[..2])
}

struct OpenChunk {
    writer: ChunkWriter,
    info: ChunkInfo,
    opened: Instant,
}

struct Appender {
    root: PathBuf,
    master: MasterKey,
    config: EngineConfig,
    shared: Arc<Shared>,
    logged: Sender<WriterMessage>,
    open: HashMap<[u8; 16], OpenChunk>,
}

pub(crate) fn spawn(
    root: PathBuf,
    master: MasterKey,
    config: EngineConfig,
    shared: Arc<Shared>,
    requests: Receiver<AppendRequest>,
    logged: Sender<WriterMessage>,
) -> std::io::Result<JoinHandle<()>> {
    std::thread::Builder::new().name("remind-appender".to_owned()).spawn(move || {
        crate::set_utility_qos();
        let mut appender = Appender { root, master, config, shared, logged, open: HashMap::new() };
        appender.run(&requests);
    })
}

impl Appender {
    fn run(&mut self, requests: &Receiver<AppendRequest>) {
        let mut last_sync = Instant::now();
        loop {
            let wait = self.config.sync_interval.saturating_sub(last_sync.elapsed());
            match requests.recv_timeout(wait) {
                Ok(AppendRequest::Sample(sample)) => self.append(&sample),
                Ok(AppendRequest::SealAll(done)) => {
                    self.seal_all();
                    let _ = done.send(());
                }
                Err(RecvTimeoutError::Timeout) => {}
                Err(RecvTimeoutError::Disconnected) => {
                    self.seal_all();
                    return;
                }
            }
            if last_sync.elapsed() >= self.config.sync_interval {
                self.sync_dirty();
                last_sync = Instant::now();
            }
        }
    }

    fn append(&mut self, sample: &Sample) {
        // A chunk has to start with a keyframe, or nothing in it can be decoded.
        // Samples queued before a failure or a seal can reach this point with no
        // chunk open, so this has to be checked here as well as at enqueue.
        if !sample.is_sync && !self.open.contains_key(&sample.display_uuid) {
            self.shared.dropped_frames.fetch_add(1, Ordering::Relaxed);
            self.shared.require_keyframe(&sample.display_uuid);
            return;
        }
        if let Err(error) = self.try_append(sample) {
            self.shared.append_failures.fetch_add(1, Ordering::Relaxed);
            self.shared.dropped_frames.fetch_add(1, Ordering::Relaxed);
            self.shared.disk_full.store(error.is_disk_full(), Ordering::Relaxed);
            // The chain is broken, and this chunk accepts nothing more.
            self.shared.require_keyframe(&sample.display_uuid);
            self.abandon(&sample.display_uuid);
        } else {
            self.shared.disk_full.store(false, Ordering::Relaxed);
        }
    }

    fn try_append(&mut self, sample: &Sample) -> remind_vault::Result<()> {
        let chunk = self.chunk_for(sample)?;
        let appended = chunk.writer.append(RecordRef {
            wall_ms: sample.wall_ms,
            mono_ns: sample.mono_ns,
            flags: if sample.is_sync { flags::SYNC } else { 0 },
            meta: &segment::encode_context(&sample.context),
            sample: &sample.data,
        })?;
        let info = chunk.info.clone();

        self.shared.logged_frames.fetch_add(1, Ordering::Relaxed);
        self.shared.logged_watermark.store(sample.mono_ns, Ordering::Release);

        let _ = self.logged.send(WriterMessage::Frame(LoggedFrame {
            chunk: info,
            seq: appended.seq,
            offset: appended.offset,
            len: appended.len,
            t_ms: sample.wall_ms,
            is_sync: sample.is_sync,
            context: sample.context.clone(),
        }));
        Ok(())
    }

    /// Returns the chunk this sample belongs in, replacing the current one if
    /// it's due. Chunks only change on a keyframe, because each must start with one.
    fn chunk_for(&mut self, sample: &Sample) -> remind_vault::Result<&mut OpenChunk> {
        let display = sample.display_uuid;
        let replace = self.open.get(&display).is_some_and(|chunk| {
            let header = chunk.writer.header();
            let changed = header.width != sample.width
                || header.height != sample.height
                || header.parameter_sets != *sample.parameter_sets;
            let due = chunk.opened.elapsed() >= self.config.chunk_max_age
                || chunk.writer.len() >= self.config.chunk_max_bytes;
            sample.is_sync && (changed || due)
        });
        if replace {
            self.seal(&display);
        }
        if !self.open.contains_key(&display) {
            let chunk = self.create_chunk(sample)?;
            self.open.insert(display, chunk);
        }
        // The entry was just ensured.
        self.open.get_mut(&display).ok_or(remind_vault::VaultError::WriterFailed)
    }

    fn create_chunk(&self, sample: &Sample) -> remind_vault::Result<OpenChunk> {
        let mut id = [0u8; 16];
        getrandom::fill(&mut id).map_err(|_| remind_vault::VaultError::Random)?;
        let relative = chunk_relative_path(&id);
        let header = ChunkHeader {
            id,
            display_uuid: sample.display_uuid,
            width: sample.width,
            height: sample.height,
            parameter_sets: sample.parameter_sets.to_vec(),
        };
        let writer = ChunkWriter::create(&path_in(&self.root, &relative), &self.master, header)?;
        Ok(OpenChunk {
            writer,
            info: ChunkInfo {
                uuid: id,
                display_uuid: sample.display_uuid,
                width: sample.width,
                height: sample.height,
                path: relative,
            },
            opened: Instant::now(),
        })
    }

    fn sync_dirty(&mut self) {
        for chunk in self.open.values_mut() {
            if chunk.writer.is_dirty() {
                // A failure here shows up on the next append or at seal.
                let _ = chunk.writer.sync();
            }
        }
    }

    fn seal(&mut self, display: &[u8; 16]) {
        if let Some(chunk) = self.open.remove(display) {
            let uuid = chunk.info.uuid;
            let is_empty = chunk.writer.is_empty();
            // If syncing fails, recovery validates the chunk on next launch, so
            // it isn't marked sealed here.
            if chunk.writer.seal().is_ok() && !is_empty {
                let _ = self.logged.send(WriterMessage::Sealed(uuid));
            }
        }
    }

    /// Stops using a chunk that failed. Recovery tidies it on the next launch.
    fn abandon(&mut self, display: &[u8; 16]) {
        self.open.remove(display);
    }

    fn seal_all(&mut self) {
        let displays: Vec<_> = self.open.keys().copied().collect();
        for display in displays {
            self.seal(&display);
            self.shared.require_keyframe(&display);
        }
    }
}

pub(crate) fn path_in(root: &Path, relative: &str) -> PathBuf {
    root.join(relative)
}
