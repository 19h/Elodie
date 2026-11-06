//! The master key and what's derived from it.

use zeroize::Zeroize;

use crate::{Result, VaultError};

/// The random 256-bit key everything else is derived from. Stored in the
/// Keychain by the app. It's wiped from memory on drop and redacted from `Debug`.
#[derive(Clone)]
pub struct MasterKey([u8; 32]);

impl Drop for MasterKey {
    fn drop(&mut self) {
        self.0.zeroize();
    }
}

impl std::fmt::Debug for MasterKey {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("MasterKey(redacted)")
    }
}

impl MasterKey {
    pub fn from_bytes(bytes: [u8; 32]) -> Self {
        Self(bytes)
    }

    /// Creates a new random key.
    pub fn generate() -> Result<Self> {
        let mut bytes = [0u8; 32];
        getrandom::fill(&mut bytes).map_err(|_| VaultError::Random)?;
        Ok(Self(bytes))
    }

    pub fn as_bytes(&self) -> &[u8; 32] {
        &self.0
    }

    /// The key for one chunk.
    pub(crate) fn chunk_key(&self, chunk_id: &[u8; 16]) -> [u8; 32] {
        let mut material = [0u8; 48];
        material[..32].copy_from_slice(&self.0);
        material[32..].copy_from_slice(chunk_id);
        let key = blake3::derive_key("elodie 2026-11 chunk key", &material);
        material.zeroize();
        key
    }

    /// The raw SQLCipher key.
    pub fn database_key(&self) -> [u8; 32] {
        blake3::derive_key("elodie 2026-11 database key", &self.0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn derived_keys_differ_by_purpose_and_chunk() {
        let master = MasterKey::from_bytes([1; 32]);
        let a = master.chunk_key(&[1; 16]);
        let b = master.chunk_key(&[2; 16]);
        assert_ne!(a, b);
        assert_ne!(a, master.database_key());
        assert_ne!(&a, master.as_bytes());
    }

    #[test]
    fn derivation_is_stable_across_releases() {
        // Known answers. Existing vaults depend on these values, so if this
        // fails, the change would orphan all recorded history.
        let master = MasterKey::from_bytes([1; 32]);
        assert_eq!(hex(&master.database_key()), "12ce994e397635f844694b3514db0cca67c77898c5dfc57d7e0216f09a130b2c");
        assert_eq!(hex(&master.chunk_key(&[2; 16])), "ae631bb722ba775d72d0da0ecd4264ccbe392a71c7a6cbd21460c11085042987");
    }

    fn hex(bytes: &[u8]) -> String {
        bytes.iter().map(|b| format!("{b:02x}")).collect()
    }

    #[test]
    fn debug_output_hides_the_key() {
        let master = MasterKey::from_bytes([0xAB; 32]);
        assert_eq!(format!("{master:?}"), "MasterKey(redacted)");
    }
}
