use chta_launcher::{install_runtime, validate_relative_path};
use flate2::{Compression, write::GzEncoder};
use sha2::{Digest, Sha256};
use std::{
    fs,
    io::Write,
    path::PathBuf,
    sync::atomic::{AtomicU64, Ordering},
};

static SERIAL: AtomicU64 = AtomicU64::new(0);
struct Fixture(PathBuf);
impl Fixture {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "chta-launcher-test-{}-{}",
            std::process::id(),
            SERIAL.fetch_add(1, Ordering::SeqCst)
        ));
        fs::create_dir(&path).unwrap();
        Self(path)
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        assert!(
            self.0
                .file_name()
                .unwrap()
                .to_string_lossy()
                .starts_with("chta-launcher-test-")
        );
        let _ = fs::remove_dir_all(&self.0);
    }
}
fn payload(name: &str, truncate: bool) -> (Vec<u8>, String) {
    let files = [
        (name, b"application".as_slice()),
        ("data/app.so", b"flutter assets".as_slice()),
    ];
    let manifest = serde_json::json!({"version":1,"entrypoint":"chta.exe","files":files.iter().map(|(path,bytes)|serde_json::json!({"path":path,"size":bytes.len(),"sha256":format!("{:x}",Sha256::digest(bytes))})).collect::<Vec<_>>()});
    let manifest = serde_json::to_vec(&manifest).unwrap();
    let mut archive = b"CHTAAPP1".to_vec();
    archive.extend((manifest.len() as u32).to_le_bytes());
    archive.extend(manifest);
    let mut compressed = GzEncoder::new(Vec::new(), Compression::fast());
    for (_, bytes) in files {
        compressed.write_all(bytes).unwrap();
    }
    archive.extend(compressed.finish().unwrap());
    if truncate {
        archive.truncate(archive.len() - 8);
    }
    let hash = format!("{:x}", Sha256::digest(&archive));
    (archive, hash)
}
#[test]
fn extracts_verified_files_and_reuses_the_immutable_runtime() {
    let dir = Fixture::new();
    let (bytes, hash) = payload("chta.exe", false);
    let first = install_runtime(&bytes, &hash, &dir.0).unwrap();
    assert_eq!(
        fs::read(first.join("data/app.so")).unwrap(),
        b"flutter assets"
    );
    assert_eq!(install_runtime(&bytes, &hash, &dir.0).unwrap(), first);
}
#[test]
fn tampered_cache_is_not_executed_and_is_repaired_separately() {
    let dir = Fixture::new();
    let (bytes, hash) = payload("chta.exe", false);
    let first = install_runtime(&bytes, &hash, &dir.0).unwrap();
    fs::write(first.join("chta.exe"), b"changed").unwrap();
    let repaired = install_runtime(&bytes, &hash, &dir.0).unwrap();
    assert_ne!(repaired, first);
    assert_eq!(fs::read(repaired.join("chta.exe")).unwrap(), b"application");
}
#[test]
fn rejects_payload_corruption_truncation_and_windows_escape_paths() {
    let dir = Fixture::new();
    let (mut bytes, hash) = payload("chta.exe", false);
    bytes[0] ^= 1;
    assert!(install_runtime(&bytes, &hash, &dir.0).is_err());
    let (bytes, hash) = payload("chta.exe", true);
    assert!(install_runtime(&bytes, &hash, &dir.0).is_err());
    for path in [
        "../outside.exe",
        "/outside.exe",
        "C:/outside.exe",
        "file:stream",
        "data\\outside.exe",
        "data/NUL.txt",
        "data/file.",
    ] {
        assert!(validate_relative_path(path).is_err(), "{path}");
        let (bytes, hash) = payload(path, false);
        assert!(install_runtime(&bytes, &hash, &dir.0).is_err());
    }
}
#[cfg(windows)]
#[test]
fn refuses_redirected_runtime_root() {
    use std::os::windows::fs::symlink_dir;
    let dir = Fixture::new();
    let elsewhere = Fixture::new();
    let link = dir.0.join("linked");
    if symlink_dir(&elsewhere.0, &link).is_err() {
        return;
    }
    let (bytes, hash) = payload("chta.exe", false);
    assert!(install_runtime(&bytes, &hash, &link).is_err());
    fs::remove_dir(&link).unwrap();
}
