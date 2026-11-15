use cht_relay::{config::Config, identity};

#[cfg(windows)]
#[test]
fn windows_credential_is_protected_and_reuses_the_same_relay_identity() {
    let directory = tempfile::tempdir().unwrap();
    let password = identity::windows_password(directory.path()).unwrap();
    let encrypted = std::fs::read(directory.path().join("credential.dpapi")).unwrap();
    assert!(
        !encrypted
            .windows(password.len())
            .any(|bytes| bytes == password.as_slice())
    );
    let peer = identity::load_or_create(directory.path(), &password)
        .unwrap()
        .public()
        .to_peer_id();
    let reopened = identity::windows_password(directory.path()).unwrap();
    assert_eq!(*password, *reopened);
    assert_eq!(
        peer,
        identity::load_or_create(directory.path(), &reopened)
            .unwrap()
            .public()
            .to_peer_id()
    );
}

#[test]
fn configuration_rejects_unsafe_or_ambiguous_values() {
    let mut config = Config {
        public_addresses: vec!["/ip4/127.0.0.1/tcp/4001".into()],
        ..Config::default()
    };
    config.validate().unwrap();
    config.port = 0;
    assert!(config.validate().is_err());
    config.port = 4001;
    for address in [
        "/ip4/0.0.0.0/tcp/4001",
        "/ip4/127.0.0.1/tcp/4002",
        "/ip4/127.0.0.1/udp/4001",
    ] {
        config.public_addresses = vec![address.into()];
        assert!(config.validate().is_err(), "{address}");
    }
    config.public_addresses.clear();
    assert!(config.validate().is_err());
    assert!(serde_json::from_str::<Config>(r#"{"unknown_option":1}"#).is_err());
    assert!(serde_json::from_str::<Config>(r#"{"limits":{"max_circutis":1}}"#).is_err());
    let mut limits = config.limits;
    limits.max_connections = 0;
    assert!(limits.validate().is_err());
    limits.max_connections = 1;
    assert!(limits.validate().is_err()); // per-peer > total
    limits.max_connections_per_peer = 1;
    limits.circuit_bytes = 0;
    assert!(limits.validate().is_err());
}

#[test]
fn peer_id_survives_restart_and_wrong_password_never_replaces_identity() {
    let dir = tempfile::tempdir().unwrap();
    let state = dir.path().join("state");
    let password = b"generated-test-secret-with-at-least-32-bytes";
    let first = identity::load_or_create(&state, password).unwrap();
    let path = state.join("identity.enc.json");
    let bytes = std::fs::read(&path).unwrap();
    let secret = first.to_protobuf_encoding().unwrap();
    assert!(!bytes.windows(secret.len()).any(|w| w == secret));
    assert!(!bytes.windows(password.len()).any(|w| w == password));
    let second = identity::load_or_create(&state, password).unwrap();
    assert_eq!(first.public().to_peer_id(), second.public().to_peer_id());
    assert!(
        identity::load_or_create(&state, b"wrong-secret-with-at-least-thirty-two-bytes").is_err()
    );
    assert_eq!(bytes, std::fs::read(&path).unwrap());
    let mut tampered: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    tampered["nonce"] = serde_json::json!("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA");
    std::fs::write(&path, serde_json::to_vec(&tampered).unwrap()).unwrap();
    assert!(identity::load_or_create(&state, password).is_err());
    std::fs::write(&path, b"corrupted").unwrap();
    assert!(identity::load_or_create(&state, password).is_err());
    assert_eq!(std::fs::read(&path).unwrap(), b"corrupted");
}

#[test]
fn credential_rejects_short_and_oversized_files() {
    use std::io::Write;
    let mut file = tempfile::NamedTempFile::new().unwrap();
    file.write_all(b"short").unwrap();
    assert!(identity::password_from_file(file.path()).is_err());
    file.write_all(&[b'x'; 4097]).unwrap();
    assert!(identity::password_from_file(file.path()).is_err());
}

#[cfg(unix)]
#[test]
fn unix_state_and_credentials_must_be_private() {
    use std::os::unix::fs::PermissionsExt;
    let dir = tempfile::tempdir().unwrap();
    let secret = dir.path().join("secret");
    std::fs::write(&secret, [b'x'; 48]).unwrap();
    std::fs::set_permissions(&secret, std::fs::Permissions::from_mode(0o644)).unwrap();
    assert!(identity::password_from_file(&secret).is_err());
    std::fs::set_permissions(&secret, std::fs::Permissions::from_mode(0o600)).unwrap();
    assert_eq!(identity::password_from_file(&secret).unwrap().len(), 48);
    identity::load_or_create(dir.path(), &[b'x'; 48]).unwrap();
    assert_eq!(
        std::fs::metadata(dir.path().join("identity.enc.json"))
            .unwrap()
            .permissions()
            .mode()
            & 0o777,
        0o600
    );
    std::fs::set_permissions(dir.path(), std::fs::Permissions::from_mode(0o755)).unwrap();
    assert!(identity::load_or_create(dir.path(), &[b'x'; 48]).is_err());
}
