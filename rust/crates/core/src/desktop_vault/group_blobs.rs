use super::{DesktopVault, atomic_write, id_hash, io_error};
use sha2::{Digest, Sha256};
use std::{fs, io::Read, path::PathBuf};
use zeroize::Zeroizing;

const MAX_BLOB_BYTES: usize = 8 * 1024 * 1024;
const MAX_ENCRYPTED_BYTES: u64 = (MAX_BLOB_BYTES + 64 * 1024) as u64;

impl DesktopVault {
    fn group_blob_path(&self, owner: &str, key: &str) -> Result<PathBuf, String> {
        let owner_hash = id_hash(owner)?;
        if key.is_empty()
            || key.len() > 128
            || !key
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
        {
            return Err("Invalid group blob key".into());
        }
        let key_hash = format!("{:x}", Sha256::digest(key.as_bytes()));
        Ok(self
            .root
            .join("group-blobs")
            .join(owner_hash)
            .join(format!("{key_hash}.bin")))
    }

    pub fn save_group_blob(&self, owner: &str, key: &str, value: &str) -> Result<(), String> {
        let path = self.group_blob_path(owner, key)?;
        if value.len() > MAX_BLOB_BYTES {
            return Err("Group blob is too large".into());
        }
        let context = format!("cht-group-blob-v1\0{owner}\0{key}");
        let ciphertext = self.protect(value.as_bytes(), context.as_bytes(), true)?;
        atomic_write(&path, &ciphertext)
    }

    pub fn load_group_blob(&self, owner: &str, key: &str) -> Result<Option<String>, String> {
        let path = self.group_blob_path(owner, key)?;
        let file = match fs::File::open(path) {
            Ok(file) => file,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(io_error(error)),
        };
        if file.metadata().map_err(io_error)?.len() > MAX_ENCRYPTED_BYTES {
            return Err("Group blob is too large".into());
        }
        let mut ciphertext = Vec::new();
        file.take(MAX_ENCRYPTED_BYTES + 1)
            .read_to_end(&mut ciphertext)
            .map_err(io_error)?;
        if ciphertext.len() as u64 > MAX_ENCRYPTED_BYTES {
            return Err("Group blob is too large".into());
        }
        let context = format!("cht-group-blob-v1\0{owner}\0{key}");
        let plaintext = Zeroizing::new(self.protect(&ciphertext, context.as_bytes(), false)?);
        if plaintext.len() > MAX_BLOB_BYTES {
            return Err("Group blob is too large".into());
        }
        String::from_utf8(plaintext.to_vec())
            .map(Some)
            .map_err(|_| "Group blob is invalid UTF-8".into())
    }

    pub fn delete_group_blob(&self, owner: &str, key: &str) -> Result<(), String> {
        let path = self.group_blob_path(owner, key)?;
        match fs::remove_file(path) {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(io_error(error)),
        }
    }
}

#[cfg(all(test, windows))]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn group_blob_encrypts_and_binds_owner_and_key() {
        let root = std::env::temp_dir().join(format!(
            "cht-group-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let vault = DesktopVault::new(root.clone());
        let alice = format!("did:cht:{}", "a".repeat(64));
        let bob = format!("did:cht:{}", "b".repeat(64));
        vault
            .save_group_blob(&alice, "page_0", "private metadata")
            .unwrap();
        assert_eq!(
            vault.load_group_blob(&alice, "page_0").unwrap().as_deref(),
            Some("private metadata")
        );
        assert_eq!(vault.load_group_blob(&bob, "page_0").unwrap(), None);
        let ap = vault.group_blob_path(&alice, "page_0").unwrap();
        let bp = vault.group_blob_path(&bob, "page_0").unwrap();
        std::fs::create_dir_all(bp.parent().unwrap()).unwrap();
        std::fs::copy(&ap, &bp).unwrap();
        assert!(vault.load_group_blob(&bob, "page_0").is_err());
        let other = vault.group_blob_path(&alice, "page_1").unwrap();
        std::fs::copy(&ap, &other).unwrap();
        assert!(vault.load_group_blob(&alice, "page_1").is_err());
        assert!(
            !std::fs::read(&ap)
                .unwrap()
                .windows(16)
                .any(|w| w == b"private metadata")
        );
        vault.delete_group_blob(&alice, "page_0").unwrap();
        assert_eq!(vault.load_group_blob(&alice, "page_0").unwrap(), None);
        std::fs::remove_dir_all(root).unwrap();
    }
}
