use cht_core::{IdentityError, IdentityManager};

const ZERO_ENTROPY_MNEMONIC: &str = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon art";

#[test]
fn new_identity_has_24_words_and_a_cht_identifier() {
    let pending = IdentityManager::create().expect("identity generation should work");

    assert_eq!(pending.mnemonic().split_whitespace().count(), 24);
    assert!(pending.public_identity().id.starts_with("did:cht:"));
    assert_eq!(pending.public_identity().id.len(), "did:cht:".len() + 64);
}

#[test]
fn the_same_mnemonic_restores_the_same_identity() {
    let first = IdentityManager::restore(ZERO_ENTROPY_MNEMONIC).expect("mnemonic is valid");
    let second = IdentityManager::restore(ZERO_ENTROPY_MNEMONIC).expect("mnemonic is valid");

    assert_eq!(first.public_identity(), second.public_identity());
}

#[test]
fn different_entropy_creates_different_identities() {
    let first = IdentityManager::create().expect("identity generation should work");
    let second = IdentityManager::create().expect("identity generation should work");

    assert_ne!(first.public_identity().id, second.public_identity().id);
}

#[test]
fn malformed_mnemonic_is_rejected() {
    assert!(matches!(
        IdentityManager::restore("not a bip39 phrase"),
        Err(IdentityError::InvalidMnemonic(_))
    ));
}

#[test]
fn recovery_confirmation_must_match_before_secret_export() {
    let mut pending = IdentityManager::create().expect("identity generation should work");

    assert_eq!(
        pending.confirm_recovery("wrong words"),
        Err(IdentityError::RecoveryConfirmationMismatch)
    );
    assert_eq!(
        pending.export_confirmed_secret(),
        Err(IdentityError::RecoveryNotConfirmed)
    );

    let phrase = pending.mnemonic().to_owned();
    pending
        .confirm_recovery(&phrase)
        .expect("matching phrase should confirm");
    assert!(
        !pending
            .export_confirmed_secret()
            .expect("confirmed secret should export")
            .is_empty()
    );
}

#[test]
fn unsupported_derivation_version_is_rejected() {
    let restored = IdentityManager::restore(ZERO_ENTROPY_MNEMONIC).expect("mnemonic is valid");
    let mut secret: serde_json::Value =
        serde_json::from_slice(&restored.export_secret()).expect("valid secret JSON");
    secret["derivationVersion"] = 99.into();

    assert_eq!(
        IdentityManager::from_secret(
            &serde_json::to_vec(&secret).expect("secret should serialize")
        ),
        Err(IdentityError::UnsupportedDerivationVersion(99))
    );
}
