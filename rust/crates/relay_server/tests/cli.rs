use std::{
    io::{BufRead, BufReader, Write},
    net::TcpListener,
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    sync::mpsc,
    time::Duration,
};

use cht_relay::config::Config;

const BINARY: &str = env!("CARGO_BIN_EXE_cht-relay");

struct Process(Child);
impl Drop for Process {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

fn start(config: &Path, credential: &Path) -> (Process, mpsc::Receiver<String>) {
    let mut child = Command::new(BINARY)
        .args(["--config"])
        .arg(config)
        .env("CHT_RELAY_KEY_PASSWORD_FILE", credential)
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    let stdout = child.stdout.take().unwrap();
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        for line in BufReader::new(stdout).lines() {
            if tx.send(line.unwrap()).is_err() {
                break;
            }
        }
    });
    (Process(child), rx)
}

fn wait_listening(lines: &mpsc::Receiver<String>) -> String {
    let mut peer_id = None;
    loop {
        let line = lines
            .recv_timeout(Duration::from_secs(20))
            .expect("server did not listen");
        let event: serde_json::Value = serde_json::from_str(&line).unwrap();
        if event["event"] == "starting" {
            peer_id = Some(event["peer_id"].as_str().unwrap().to_owned());
        }
        if event["event"] == "listening" {
            return peer_id.unwrap();
        }
    }
}

#[test]
fn executable_keeps_peer_id_across_restarts_and_fails_on_wrong_credential() {
    let dir = tempfile::tempdir().unwrap();
    let port = TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port();
    let config_path: PathBuf = dir.path().join("relay.json");
    let config = Config {
        listen_ip: "127.0.0.1".parse().unwrap(),
        port,
        public_addresses: vec![format!("/ip4/127.0.0.1/tcp/{port}")],
        state_dir: dir.path().join("state"),
        ..Config::default()
    };
    std::fs::write(&config_path, serde_json::to_vec(&config).unwrap()).unwrap();
    let mut secret = tempfile::NamedTempFile::new_in(dir.path()).unwrap();
    secret
        .write_all(b"random-secret-for-local-cli-tests-at-least-32-bytes")
        .unwrap();
    let checked = Command::new(BINARY)
        .arg("--config")
        .arg(&config_path)
        .arg("--check-config")
        .env_remove("CHT_RELAY_KEY_PASSWORD_FILE")
        .output()
        .unwrap();
    assert!(checked.status.success());
    assert!(!config.state_dir.exists());
    let (process, lines) = start(&config_path, secret.path());
    let first = wait_listening(&lines);
    drop(process);
    let (process, lines) = start(&config_path, secret.path());
    assert_eq!(first, wait_listening(&lines));
    drop(process);
    let original = std::fs::read(config.state_dir.join("identity.enc.json")).unwrap();
    secret.as_file_mut().set_len(0).unwrap();
    std::fs::write(
        secret.path(),
        b"incorrect-secret-for-local-cli-tests-at-least-32-bytes",
    )
    .unwrap();
    let failed = Command::new(BINARY)
        .arg("--config")
        .arg(&config_path)
        .arg("--print-peer-id")
        .env("CHT_RELAY_KEY_PASSWORD_FILE", secret.path())
        .output()
        .unwrap();
    assert!(!failed.status.success());
    assert!(String::from_utf8_lossy(&failed.stderr).contains("Unable to unlock"));
    assert_eq!(
        original,
        std::fs::read(config.state_dir.join("identity.enc.json")).unwrap()
    );
}
