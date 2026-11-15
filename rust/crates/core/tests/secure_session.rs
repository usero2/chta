use cht_core::{IdentityManager, SecureSession};

#[test]
fn duplicate_window_stays_bounded_during_long_file_streams() {
    let a = IdentityManager::create().unwrap();
    let b = IdentityManager::create().unwrap();
    let mut left = SecureSession::initiator(&a, b.public_identity()).unwrap();
    let mut right = SecureSession::responder(&b, a.public_identity()).unwrap();
    let reply = right
        .receive_handshake(&left.start_handshake().unwrap())
        .unwrap()
        .unwrap();
    left.receive_handshake(&reply).unwrap();
    for i in 0..4100 {
        let frame = left
            .encrypt_message(&format!("part-{i}"), b"piece")
            .unwrap();
        assert!(!right.decrypt_message(&frame).unwrap().duplicate);
    }
    let old = left
        .encrypt_message("part-0", b"old duplicate outside window")
        .unwrap();
    assert!(!right.decrypt_message(&old).unwrap().duplicate);
    let recent = left
        .encrypt_message("part-4099", b"recent duplicate")
        .unwrap();
    assert!(right.decrypt_message(&recent).unwrap().duplicate);
}

#[test]
fn noise_kk_establishes_and_encrypts_between_signed_identity_keys() {
    let alice = IdentityManager::create().expect("alice identity");
    let bob = IdentityManager::create().expect("bob identity");
    let mut initiator =
        SecureSession::initiator(&alice, bob.public_identity()).expect("initiator should build");
    let mut responder =
        SecureSession::responder(&bob, alice.public_identity()).expect("responder should build");

    let first = initiator
        .start_handshake()
        .expect("initiator should write first handshake frame");
    let second = responder
        .receive_handshake(&first)
        .expect("responder should read first frame")
        .expect("responder should reply");
    assert!(responder.is_established());
    assert!(
        initiator
            .receive_handshake(&second)
            .expect("initiator should read reply")
            .is_none()
    );
    assert!(initiator.is_established());

    let encrypted = initiator
        .encrypt_message_at("message-1", b"hello encrypted world", Some(1794500000123))
        .expect("encryption should work");
    assert!(!String::from_utf8_lossy(&encrypted).contains("hello encrypted world"));
    let decrypted = responder
        .decrypt_message(&encrypted)
        .expect("decryption should work");

    assert_eq!(decrypted.message_id, "message-1");
    assert_eq!(decrypted.plaintext, b"hello encrypted world");
    assert!(!decrypted.duplicate);
    assert_eq!(decrypted.sent_at_milliseconds, Some(1794500000123));
}

#[test]
fn duplicate_message_ids_are_detected_without_duplicate_delivery() {
    let alice = IdentityManager::create().expect("alice identity");
    let bob = IdentityManager::create().expect("bob identity");
    let (mut initiator, mut responder) = established_pair(&alice, &bob);

    let first = initiator
        .encrypt_message("same-id", b"first attempt")
        .expect("encryption should work");
    let retry = initiator
        .encrypt_message("same-id", b"retry attempt")
        .expect("retry encryption should work");

    assert!(
        !responder
            .decrypt_message(&first)
            .expect("first should decrypt")
            .duplicate
    );
    assert!(
        responder
            .decrypt_message(&retry)
            .expect("retry should decrypt")
            .duplicate
    );
}

fn established_pair(
    alice: &IdentityManager,
    bob: &IdentityManager,
) -> (SecureSession, SecureSession) {
    let mut initiator =
        SecureSession::initiator(alice, bob.public_identity()).expect("initiator should build");
    let mut responder =
        SecureSession::responder(bob, alice.public_identity()).expect("responder should build");
    let first = initiator.start_handshake().expect("first frame");
    let second = responder
        .receive_handshake(&first)
        .expect("responder read")
        .expect("responder reply");
    initiator
        .receive_handshake(&second)
        .expect("initiator read");
    (initiator, responder)
}
