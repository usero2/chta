use super::*;

const MAX_SIZE: u64 = 10 * 1024 * 1024 * 1024;
const MAX_CHUNK: u32 = 1024 * 1024;

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct ChunkedAttachmentState {
    version: u32,
    pub id: String,
    pub size: u64,
    pub chunk_size: u32,
    pub contiguous_chunks: u32,
    pub completed: bool,
    pub digest: Option<String>,
}

impl ChunkedAttachmentState {
    fn count(&self) -> u32 {
        self.size.div_ceil(self.chunk_size as u64) as u32
    }
    fn validate(&self) -> Result<(), String> {
        if self.version != 2
            || self.id.len() < 16
            || self.id.len() > 96
            || !self
                .id
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"_-".contains(&b))
            || self.size > MAX_SIZE
            || self.chunk_size == 0
            || self.chunk_size > MAX_CHUNK
            || self.size.div_ceil(self.chunk_size as u64) > 100000
            || self.contiguous_chunks > self.count()
            || (self.completed && (self.contiguous_chunks != self.count() || self.digest.is_none()))
            || self.digest.as_ref().is_some_and(|s| {
                s.len() != 64
                    || !s
                        .bytes()
                        .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
            })
        {
            return Err("Invalid chunked attachment metadata".into());
        }
        Ok(())
    }
    fn length(&self, index: u32) -> Result<usize, String> {
        if index >= self.count() {
            return Err("Invalid attachment chunk index".into());
        }
        Ok(
            (self.size - index as u64 * self.chunk_size as u64).min(self.chunk_size as u64)
                as usize,
        )
    }
}

fn bounded_read(path: &Path, maximum: u64) -> Result<Vec<u8>, String> {
    let metadata = fs::symlink_metadata(path).map_err(io_error)?;
    if !metadata.is_file() || metadata.file_type().is_symlink() || metadata.len() > maximum {
        return Err("Invalid encrypted attachment cache file".into());
    }
    let mut result = Vec::new();
    fs::File::open(path)
        .map_err(io_error)?
        .take(maximum + 1)
        .read_to_end(&mut result)
        .map_err(io_error)?;
    if result.len() as u64 > maximum {
        return Err("Attachment cache file is too large".into());
    }
    Ok(result)
}

impl DesktopVault {
    fn chunk_directory(&self, owner: &str, id: &str) -> Result<PathBuf, String> {
        let placeholder = ChunkedAttachmentState {
            version: 2,
            id: id.into(),
            size: 0,
            chunk_size: 1,
            contiguous_chunks: 0,
            completed: false,
            digest: None,
        };
        placeholder.validate()?;
        let hash = id_hash(owner)?;
        let mut path = self.root.clone();
        for part in ["chunked-attachments", hash, id] {
            path.push(part);
            match fs::symlink_metadata(&path) {
                Ok(metadata) if !metadata.is_dir() || metadata.file_type().is_symlink() => {
                    return Err("Invalid attachment cache directory".into());
                }
                Ok(_) => {}
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                Err(error) => return Err(io_error(error)),
            }
        }
        Ok(path)
    }

    fn chunk_manifest(&self, owner: &str, id: &str) -> Result<ChunkedAttachmentState, String> {
        let path = self.chunk_directory(owner, id)?.join("manifest.bin");
        let protected = bounded_read(&path, 32768)?;
        let entropy = format!("cht-chunk-manifest-v2:{owner}:{id}");
        let plain = Zeroizing::new(self.protect(&protected, entropy.as_bytes(), false)?);
        let state: ChunkedAttachmentState =
            serde_json::from_slice(&plain).map_err(|_| "Invalid attachment manifest".to_owned())?;
        state.validate()?;
        if state.id != id {
            return Err("Attachment manifest identity mismatch".into());
        }
        Ok(state)
    }

    fn save_chunk_manifest(
        &self,
        owner: &str,
        state: &ChunkedAttachmentState,
    ) -> Result<(), String> {
        state.validate()?;
        let entropy = format!("cht-chunk-manifest-v2:{owner}:{}", state.id);
        let bytes = Zeroizing::new(serde_json::to_vec(state).map_err(|e| e.to_string())?);
        let encrypted = self.protect(&bytes, entropy.as_bytes(), true)?;
        atomic_write(
            &self.chunk_directory(owner, &state.id)?.join("manifest.bin"),
            &encrypted,
        )
    }

    fn chunk_bytes(
        &self,
        owner: &str,
        state: &ChunkedAttachmentState,
        index: u32,
    ) -> Result<Zeroizing<Vec<u8>>, String> {
        let expected = state.length(index)?;
        let bytes = bounded_read(
            &self
                .chunk_directory(owner, &state.id)?
                .join(format!("{index:08}.bin")),
            MAX_CHUNK as u64 + 65536,
        )?;
        let entropy = format!(
            "cht-chunk-v2:{owner}:{}:{index}:{}:{}",
            state.id, state.size, state.chunk_size
        );
        let plain = Zeroizing::new(self.protect(&bytes, entropy.as_bytes(), false)?);
        if plain.len() != expected {
            return Err("Attachment chunk length mismatch".into());
        }
        Ok(plain)
    }

    pub(crate) fn begin_chunked_attachment(
        &self,
        owner: &str,
        id: &str,
        size: u64,
        chunk_size: u32,
        digest: Option<&str>,
    ) -> Result<ChunkedAttachmentState, String> {
        let state = ChunkedAttachmentState {
            version: 2,
            id: id.into(),
            size,
            chunk_size,
            contiguous_chunks: 0,
            completed: false,
            digest: digest.map(str::to_owned),
        };
        state.validate()?;
        let dir = self.chunk_directory(owner, id)?;
        if dir.join("manifest.bin").exists() {
            let previous = self.chunked_attachment_status(owner, id)?;
            if previous.size != size
                || previous.chunk_size != chunk_size
                || digest.is_some_and(|d| previous.digest.as_deref().is_some_and(|old| old != d))
            {
                return Err("Attachment transfer metadata changed".into());
            }
            return Ok(previous);
        }
        fs::create_dir_all(&dir).map_err(io_error)?;
        self.save_chunk_manifest(owner, &state)?;
        Ok(state)
    }

    pub(crate) fn chunked_attachment_status(
        &self,
        owner: &str,
        id: &str,
    ) -> Result<ChunkedAttachmentState, String> {
        let state = self.chunk_manifest(owner, id)?;
        // Resume only authenticated durable chunks, without accumulating them.
        for index in 0..state.contiguous_chunks {
            self.chunk_bytes(owner, &state, index)?;
        }
        Ok(state)
    }

    pub(crate) fn write_chunked_attachment(
        &self,
        owner: &str,
        id: &str,
        index: u32,
        bytes: &[u8],
    ) -> Result<(), String> {
        let mut state = self.chunk_manifest(owner, id)?;
        if bytes.len() != state.length(index)? || index > state.contiguous_chunks {
            return Err("Attachment chunk is out of order or has invalid length".into());
        }
        let path = self
            .chunk_directory(owner, id)?
            .join(format!("{index:08}.bin"));
        if path.exists() {
            if self.chunk_bytes(owner, &state, index)?.as_slice() != bytes {
                return Err("Attachment chunk conflicts with cached data".into());
            }
        } else {
            if index < state.contiguous_chunks || state.completed {
                return Err("A durable attachment chunk is missing".into());
            }
            let entropy = format!(
                "cht-chunk-v2:{owner}:{id}:{index}:{}:{}",
                state.size, state.chunk_size
            );
            let encrypted = self.protect(bytes, entropy.as_bytes(), true)?;
            atomic_write(&path, &encrypted)?;
        }
        if index == state.contiguous_chunks {
            state.contiguous_chunks += 1;
            self.save_chunk_manifest(owner, &state)?;
        }
        Ok(())
    }

    pub(crate) fn read_chunked_attachment(
        &self,
        owner: &str,
        id: &str,
        index: u32,
    ) -> Result<Vec<u8>, String> {
        let state = self.chunk_manifest(owner, id)?;
        if index >= state.contiguous_chunks {
            return Err("Attachment chunk has not been saved".into());
        }
        Ok(self.chunk_bytes(owner, &state, index)?.to_vec())
    }

    pub(crate) fn finish_chunked_attachment(
        &self,
        owner: &str,
        id: &str,
        expected_digest: Option<&str>,
    ) -> Result<ChunkedAttachmentState, String> {
        let mut state = self.chunk_manifest(owner, id)?;
        if state.contiguous_chunks != state.count() {
            return Err("Attachment is incomplete".into());
        }
        let mut hash = Sha256::new();
        for index in 0..state.count() {
            hash.update(&*self.chunk_bytes(owner, &state, index)?);
        }
        let actual = format!("{:x}", hash.finalize());
        if expected_digest.is_some_and(|d| d != actual)
            || state.digest.as_ref().is_some_and(|d| d != &actual)
        {
            return Err("Attachment failed final SHA-256 verification".into());
        }
        state.digest = Some(actual);
        state.completed = true;
        self.save_chunk_manifest(owner, &state)?;
        Ok(state)
    }

    pub(crate) fn delete_chunked_attachment(&self, owner: &str, id: &str) -> Result<(), String> {
        let path = self.chunk_directory(owner, id)?;
        if path.exists() {
            fs::remove_dir_all(path).map_err(io_error)?;
        }
        Ok(())
    }
}
#[cfg(all(test, windows))]
mod tests {
    use super::*;
    const OWNER: &str = "did:cht:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const OTHER: &str = "did:cht:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    const ID: &str = "chunk-cache-fixture-0001";
    #[test]
    fn large_encrypted_file_streams_and_resumes_with_a_single_block_buffer() {
        let folder = Fixture::new();
        let mut vault = folder.vault();
        let size = 129u64 * 1024 * 1024 + 123;
        let block_size = 256u32 * 1024;
        vault
            .begin_chunked_attachment(OWNER, ID, size, block_size, None)
            .unwrap();
        let count = size.div_ceil(block_size as u64) as u32;
        let mut expected = Sha256::new();
        for index in 0..count {
            let length = (size - index as u64 * block_size as u64).min(block_size as u64) as usize;
            let data = vec![(index % 251) as u8; length];
            assert!(data.len() <= 256 * 1024);
            expected.update(&data);
            if index == 100 {
                vault = folder.vault();
                assert_eq!(
                    vault
                        .begin_chunked_attachment(OWNER, ID, size, block_size, None)
                        .unwrap()
                        .contiguous_chunks,
                    100
                );
            }
            vault
                .write_chunked_attachment(OWNER, ID, index, &data)
                .unwrap();
        }
        let digest = format!("{:x}", expected.finalize());
        let final_state = vault
            .finish_chunked_attachment(OWNER, ID, Some(&digest))
            .unwrap();
        assert!(final_state.completed);
        assert_eq!(final_state.size, size);
        assert_eq!(final_state.digest.as_deref(), Some(digest.as_str()));
        assert_eq!(
            vault
                .read_chunked_attachment(OWNER, ID, count - 1)
                .unwrap()
                .len(),
            123
        );
    }
    struct Fixture(PathBuf);
    impl Fixture {
        fn new() -> Self {
            let mut random = [0u8; 16];
            getrandom::fill(&mut random).unwrap();
            Self(std::env::temp_dir().join(format!("cht-chunks-{:x}", u128::from_le_bytes(random))))
        }
        fn vault(&self) -> DesktopVault {
            DesktopVault::new(self.0.clone())
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            assert!(self.0.starts_with(std::env::temp_dir()));
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    #[test]
    fn encrypted_chunks_resume_and_verify_without_whole_file_buffers() {
        let folder = Fixture::new();
        let vault = folder.vault();
        let s = vault
            .begin_chunked_attachment(OWNER, ID, 9, 4, None)
            .unwrap();
        assert_eq!(s.contiguous_chunks, 0);
        vault
            .write_chunked_attachment(OWNER, ID, 0, b"abcd")
            .unwrap();
        assert!(
            vault
                .write_chunked_attachment(OWNER, ID, 0, b"evil")
                .is_err()
        );
        vault
            .write_chunked_attachment(OWNER, ID, 0, b"abcd")
            .unwrap();
        assert!(vault.write_chunked_attachment(OWNER, ID, 2, b"i").is_err());
        let reopened = folder.vault();
        assert_eq!(
            reopened
                .chunked_attachment_status(OWNER, ID)
                .unwrap()
                .contiguous_chunks,
            1
        );
        assert!(reopened.read_chunked_attachment(OTHER, ID, 0).is_err());
        reopened
            .write_chunked_attachment(OWNER, ID, 1, b"efgh")
            .unwrap();
        reopened
            .write_chunked_attachment(OWNER, ID, 2, b"i")
            .unwrap();
        let expected = format!("{:x}", Sha256::digest(b"abcdefghi"));
        assert!(
            reopened
                .finish_chunked_attachment(OWNER, ID, Some(&"0".repeat(64)))
                .is_err()
        );
        let result = reopened
            .finish_chunked_attachment(OWNER, ID, Some(&expected))
            .unwrap();
        assert!(result.completed);
        assert_eq!(result.digest.as_deref(), Some(expected.as_str()));
        assert_eq!(
            reopened.read_chunked_attachment(OWNER, ID, 2).unwrap(),
            b"i"
        );
        let dir = reopened.chunk_directory(OWNER, ID).unwrap();
        assert!(
            !fs::read(dir.join("00000000.bin"))
                .unwrap()
                .windows(4)
                .any(|b| b == b"abcd")
        );
        assert!(
            reopened
                .begin_chunked_attachment(OWNER, ID, 10, 4, None)
                .is_err()
        );
        reopened.delete_chunked_attachment(OWNER, ID).unwrap();
        assert!(reopened.chunked_attachment_status(OWNER, ID).is_err());
    }
    #[test]
    fn corrupt_and_failed_manifest_writes_never_advance_durable_progress() {
        let folder = Fixture::new();
        let vault = folder.vault();
        vault
            .begin_chunked_attachment(OWNER, ID, 8, 4, None)
            .unwrap();
        let dir = vault.chunk_directory(OWNER, ID).unwrap();
        fs::create_dir(dir.join("manifest.tmp")).unwrap();
        assert!(
            vault
                .write_chunked_attachment(OWNER, ID, 0, b"abcd")
                .is_err()
        );
        fs::remove_dir(dir.join("manifest.tmp")).unwrap();
        assert_eq!(
            vault
                .chunked_attachment_status(OWNER, ID)
                .unwrap()
                .contiguous_chunks,
            0
        );
        vault
            .write_chunked_attachment(OWNER, ID, 0, b"abcd")
            .unwrap();
        fs::write(dir.join("00000000.bin"), b"damaged").unwrap();
        assert!(vault.chunked_attachment_status(OWNER, ID).is_err());
        assert!(vault.finish_chunked_attachment(OWNER, ID, None).is_err());
    }
    #[test]
    fn validates_paths_counts_and_actual_chunk_length_before_storage() {
        let folder = Fixture::new();
        let vault = folder.vault();
        for id in ["../../escape", "short", "abcdefghijklmnop/evil"] {
            assert!(
                vault
                    .begin_chunked_attachment(OWNER, id, 4, 4, None)
                    .is_err()
            );
        }
        assert!(
            vault
                .begin_chunked_attachment(OWNER, ID, 10 * 1024 * 1024 * 1024 + 1, 262144, None)
                .is_err()
        );
        assert!(
            vault
                .begin_chunked_attachment(OWNER, ID, 100001, 1, None)
                .is_err()
        );
        assert!(
            vault
                .begin_chunked_attachment(OWNER, ID, 4, 0, None)
                .is_err()
        );
        vault
            .begin_chunked_attachment(OWNER, ID, 4, 4, None)
            .unwrap();
        assert!(
            vault
                .write_chunked_attachment(OWNER, ID, 0, b"abc")
                .is_err()
        );
        assert_eq!(
            vault
                .chunked_attachment_status(OWNER, ID)
                .unwrap()
                .contiguous_chunks,
            0
        );
    }
}
