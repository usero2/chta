//! Validated installation of the embedded desktop runtime.
use flate2::bufread::GzDecoder;
use serde::Deserialize;
use sha2::{Digest, Sha256};
use std::{
    collections::HashSet,
    fs,
    io::{self, Cursor, Read, Write},
    path::{Component, Path, PathBuf},
    sync::atomic::{AtomicU64, Ordering},
    time::{SystemTime, UNIX_EPOCH},
};

pub type Result<T> = std::result::Result<T, Box<dyn std::error::Error + Send + Sync>>;
const MAX_TOTAL: u64 = 2 * 1024 * 1024 * 1024;
static SERIAL: AtomicU64 = AtomicU64::new(0);
fn invalid(message: &str) -> Box<dyn std::error::Error + Send + Sync> {
    io::Error::new(io::ErrorKind::InvalidData, message).into()
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Manifest {
    version: u8,
    entrypoint: String,
    files: Vec<Entry>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Entry {
    path: String,
    size: u64,
    sha256: String,
}

pub fn validate_relative_path(value: &str) -> Result<()> {
    if value.is_empty()
        || value.len() > 1024
        || value.contains(['\\', ':'])
        || value.bytes().any(|v| v < 32 || v == 127)
        || Path::new(value)
            .components()
            .any(|v| !matches!(v, Component::Normal(_)))
    {
        return Err(invalid("Invalid runtime path"));
    }
    for part in value.split('/') {
        if part.is_empty()
            || part.len() > 255
            || part.ends_with(['.', ' '])
            || part.contains(['<', '>', '"', '|', '?', '*'])
        {
            return Err(invalid("Invalid Windows filename"));
        }
        let stem = part.split('.').next().unwrap_or("").to_ascii_uppercase();
        if matches!(stem.as_str(), "CON" | "PRN" | "AUX" | "NUL")
            || (stem.len() == 4
                && (stem.starts_with("COM") || stem.starts_with("LPT"))
                && matches!(stem.as_bytes()[3], b'1'..=b'9'))
        {
            return Err(invalid("Reserved Windows filename"));
        }
    }
    Ok(())
}
fn hash_ok(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
fn redirected(path: &Path) -> Result<bool> {
    let metadata = fs::symlink_metadata(path)?;
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        Ok(metadata.file_attributes() & 0x400 != 0)
    }
    #[cfg(not(windows))]
    {
        Ok(metadata.file_type().is_symlink())
    }
}
fn safe_ancestors(path: &Path) -> Result<()> {
    for component in path.ancestors() {
        match fs::symlink_metadata(component) {
            Ok(_) if redirected(component)? => {
                return Err(invalid("Runtime directory is a link or reparse point"));
            }
            Ok(_) => (),
            Err(error) if error.kind() == io::ErrorKind::NotFound => (),
            Err(error) => return Err(error.into()),
        }
    }
    Ok(())
}
fn parse_archive(payload: &[u8], expected_hash: &str) -> Result<(Manifest, usize)> {
    if !hash_ok(expected_hash)
        || payload.len() < 12
        || payload.len() as u64 > MAX_TOTAL
        || &payload[..8] != b"CHTAAPP1"
        || format!("{:x}", Sha256::digest(payload)) != expected_hash
    {
        return Err(invalid("Desktop payload checksum failed"));
    }
    let length = u32::from_le_bytes(payload[8..12].try_into()?) as usize;
    if length > 1024 * 1024 || length > payload.len() - 12 {
        return Err(invalid("Invalid desktop manifest length"));
    }
    let manifest: Manifest = serde_json::from_slice(&payload[12..12 + length])?;
    if manifest.version != 1
        || manifest.entrypoint != "chta.exe"
        || manifest.files.is_empty()
        || manifest.files.len() > 5000
    {
        return Err(invalid("Invalid desktop manifest"));
    }
    let mut names = HashSet::new();
    let mut total = 0u64;
    for entry in &manifest.files {
        validate_relative_path(&entry.path)?;
        if !names.insert(entry.path.to_ascii_lowercase())
            || !hash_ok(&entry.sha256)
            || entry.size > 512 * 1024 * 1024
        {
            return Err(invalid("Invalid or duplicate runtime file"));
        }
        total = total
            .checked_add(entry.size)
            .ok_or_else(|| invalid("Runtime size overflow"))?;
        if total > MAX_TOTAL {
            return Err(invalid("Desktop runtime is too large"));
        }
    }
    if !manifest
        .files
        .iter()
        .any(|entry| entry.path == manifest.entrypoint)
    {
        return Err(invalid("Missing desktop entrypoint"));
    }
    Ok((manifest, 12 + length))
}
fn verify_runtime(directory: &Path, manifest: &Manifest) -> Result<()> {
    safe_ancestors(directory)?;
    let expected: HashSet<_> = manifest
        .files
        .iter()
        .map(|entry| entry.path.as_str())
        .collect();
    let mut directories = vec![directory.to_path_buf()];
    let mut observed = 0;
    while let Some(current) = directories.pop() {
        for child in fs::read_dir(&current)? {
            let child = child?;
            let path = child.path();
            if redirected(&path)? {
                return Err(invalid("Redirected runtime file"));
            }
            if child.file_type()?.is_dir() {
                directories.push(path);
                continue;
            }
            let name = path
                .strip_prefix(directory)?
                .to_str()
                .ok_or_else(|| invalid("Invalid runtime filename"))?
                .replace('\\', "/");
            if !expected.contains(name.as_str()) {
                return Err(invalid("Unexpected runtime file"));
            }
            observed += 1;
        }
    }
    if observed != manifest.files.len() {
        return Err(invalid("Missing runtime files"));
    }
    let mut buffer = [0u8; 65536];
    for entry in &manifest.files {
        let path = directory.join(&entry.path);
        if fs::metadata(&path)?.len() != entry.size {
            return Err(invalid("Runtime file size changed"));
        }
        let mut file = fs::File::open(path)?;
        let mut hash = Sha256::new();
        loop {
            let count = file.read(&mut buffer)?;
            if count == 0 {
                break;
            }
            hash.update(&buffer[..count]);
        }
        if format!("{:x}", hash.finalize()) != entry.sha256 {
            return Err(invalid("Runtime file checksum changed"));
        }
    }
    Ok(())
}
fn extract(payload: &[u8], offset: usize, manifest: &Manifest, stage: &Path) -> Result<()> {
    let compressed = &payload[offset..];
    let mut reader = GzDecoder::new(Cursor::new(compressed));
    let mut buffer = [0u8; 65536];
    for entry in &manifest.files {
        let path = stage.join(&entry.path);
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
            safe_ancestors(parent)?;
        }
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(path)?;
        let mut remaining = entry.size;
        let mut hash = Sha256::new();
        while remaining > 0 {
            let bound = remaining.min(buffer.len() as u64) as usize;
            let count = reader.read(&mut buffer[..bound])?;
            if count == 0 {
                return Err(invalid("Truncated desktop payload"));
            }
            file.write_all(&buffer[..count])?;
            hash.update(&buffer[..count]);
            remaining -= count as u64;
        }
        file.sync_all()?;
        if format!("{:x}", hash.finalize()) != entry.sha256 {
            return Err(invalid("Extracted desktop file checksum failed"));
        }
    }
    if reader.read(&mut buffer[..1])? != 0
        || reader.into_inner().position() != compressed.len() as u64
    {
        return Err(invalid("Unexpected trailing desktop payload"));
    }
    Ok(())
}

/// Installs an immutable, content-addressed runtime; never alters account data.
pub fn install_runtime(payload: &[u8], expected_hash: &str, cache_root: &Path) -> Result<PathBuf> {
    let (manifest, offset) = parse_archive(payload, expected_hash)?;
    safe_ancestors(cache_root)?;
    fs::create_dir_all(cache_root)?;
    safe_ancestors(cache_root)?;
    let stem = &expected_hash[..32];
    let mut destination = None;
    for repair in 0..4 {
        let name = if repair == 0 {
            stem.to_owned()
        } else {
            format!("{stem}-repair{repair}")
        };
        let path = cache_root.join(name);
        if fs::symlink_metadata(&path).is_ok() {
            if verify_runtime(&path, &manifest).is_ok() {
                return Ok(path);
            }
        } else {
            destination = Some(path);
            break;
        }
    }
    let destination = destination
        .ok_or_else(|| invalid("Runtime cache needs repair; no safe installation slot remains"))?;
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos();
    let stage = cache_root.join(format!(
        ".stage-{}-{stamp}-{}",
        std::process::id(),
        SERIAL.fetch_add(1, Ordering::Relaxed)
    ));
    fs::create_dir(&stage)?;
    let result = (|| {
        extract(payload, offset, &manifest, &stage)?;
        verify_runtime(&stage, &manifest)?;
        match fs::rename(&stage, &destination) {
            Ok(()) => Ok(destination.clone()),
            Err(_) if verify_runtime(&destination, &manifest).is_ok() => Ok(destination.clone()),
            Err(error) => Err(error.into()),
        }
    })();
    // Only our unique direct child staging folder can be removed on failure/race.
    if stage.parent() == Some(cache_root)
        && stage
            .file_name()
            .is_some_and(|name| name.to_string_lossy().starts_with(".stage-"))
        && safe_ancestors(&stage).is_ok()
    {
        let _ = fs::remove_dir_all(&stage);
    }
    result
}
