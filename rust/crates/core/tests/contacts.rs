use base64::{Engine as _, engine::general_purpose::STANDARD};
use cht_core::{AccountCore, ContactError, ContactRecord, ContactStore, IdentityManager};

#[test]
fn restoring_contact_checkpoint_keeps_identity_and_rejects_invalid_cards() {
    let root = IdentityManager::create().unwrap();
    let peer = IdentityManager::create().unwrap();
    let mut core = AccountCore::new(Some(&root.export_secret()), None).unwrap();
    let before = core.contacts_state_json().unwrap();
    core.add_contact(
        &peer.contact_card().unwrap().to_json().unwrap(),
        "Temporary",
    )
    .unwrap();
    core.restore_contacts_state_json(&before).unwrap();
    assert_eq!(core.contacts_json().unwrap(), "[]");
    assert_eq!(
        core.identity_json().unwrap(),
        serde_json::to_string(root.public_identity()).unwrap()
    );
    assert!(
        core.restore_contacts_state_json("{\"contacts\":[{\"signature\":\"invalid\"}]}")
            .is_err()
    );
    assert_eq!(core.contacts_json().unwrap(), "[]");
}

// The Rust boundary checks JPEG size metadata without decoding image pixels.
fn avatar_header(size: u8) -> String {
    STANDARD.encode([
        0xff, 0xd8, 0xff, 0xc0, 0, 11, 8, 0, size, 0, size, 1, 1, 0x11, 0, 0xff, 0xd9,
    ])
}

#[test]
fn relay_catalog_capability_is_signed_and_verified() {
    let identity = IdentityManager::create().unwrap();
    let card = identity.contact_card().unwrap().to_json().unwrap();
    let verified = ContactStore::verify_card(&card).unwrap();
    assert!(verified.card.capabilities.iter().any(|v|v=="delivery-v2"));
    assert!(verified.card.capabilities.iter().any(|v| v == "message-actions-v1"));
    assert!(
        verified
            .card
            .capabilities
            .iter()
            .any(|value| value == "file-offers-v1")
    );
    assert!(verified.card.capabilities.iter().any(|v|v=="courier-v1"));
    assert!(
        verified
            .card
            .capabilities
            .iter()
            .any(|value| value == "files-v2")
    );
    assert!(
        verified
            .card
            .capabilities
            .iter()
            .any(|value| value == "relay-catalog-v1")
    );
    let tampered = card.replace("relay-catalog-v1", "relay-catalog-v2");
    assert!(matches!(
        ContactStore::verify_card(&tampered),
        Err(ContactError::InvalidSignature)
    ));
}

#[test]
fn relay_routes_are_signed_public_and_backward_compatible() {
    let identity = IdentityManager::create().unwrap();
    let old = identity
        .contact_card_with_name("Alice")
        .unwrap()
        .to_json()
        .unwrap();
    assert!(!old.contains("relayUrls"));
    ContactStore::verify_card(&old).unwrap();
    let urls = vec![
        "wss://one.trycloudflare.com/cht".into(),
        "wss://two.trycloudflare.com/cht".into(),
    ];
    let card = identity
        .contact_card_with_relays("Alice", &avatar_header(48), &urls)
        .unwrap();
    assert_eq!(
        ContactStore::verify_card(&card.to_json().unwrap())
            .unwrap()
            .card
            .relay_urls,
        urls
    );
    let tampered = card
        .to_json()
        .unwrap()
        .replace("one.trycloudflare.com", "other.trycloudflare.com");
    assert!(matches!(
        ContactStore::verify_card(&tampered),
        Err(ContactError::InvalidSignature)
    ));
    for endpoint in [
        "ws://example.com/cht",
        "wss://127.0.0.1/cht",
        "wss://192.168.1.1/cht",
    ] {
        assert!(
            identity
                .contact_card_with_relays("Alice", "", &[endpoint.into()])
                .is_err()
        );
    }
    assert!(
        identity
            .contact_card_with_relays("Alice", "", &vec![urls[0].clone(); 3])
            .is_err()
    );
    let mut jpeg = STANDARD.decode(avatar_header(48)).unwrap();
    jpeg.resize(1024, 0);
    let long_url = format!(
        "wss://{}.{}.{}.{}/cht",
        "a".repeat(60),
        "b".repeat(60),
        "c".repeat(60),
        "d".repeat(63)
    );
    let largest = identity
        .contact_card_with_relays(
            &"😀".repeat(64),
            &STANDARD.encode(jpeg),
            &[long_url.clone(), long_url],
        )
        .unwrap()
        .to_json()
        .unwrap();
    assert!(
        largest.len() <= 2953,
        "contact QR exceeds byte capacity: {}",
        largest.len()
    );
}

#[test]
fn avatar_is_signed_and_oversize_thumbnails_are_rejected() {
    let identity = IdentityManager::create().unwrap();
    let mut card = identity
        .contact_card_with_profile("Alice", &avatar_header(48))
        .unwrap();
    let verified = ContactStore::verify_card(&card.to_json().unwrap()).unwrap();
    assert_eq!(verified.card.avatar, avatar_header(48));
    assert!(card.to_json().unwrap().len() < 2900, "card should fit a QR");
    card.avatar = avatar_header(32);
    assert!(matches!(
        ContactStore::verify_card(&card.to_json().unwrap()),
        Err(ContactError::InvalidSignature)
    ));
    assert!(
        identity
            .contact_card_with_profile("Alice", &avatar_header(65))
            .is_err()
    );
    assert!(
        identity
            .contact_card_with_profile("Alice", &"A".repeat(1369))
            .is_err()
    );
}

#[test]
fn reconnect_refreshes_the_signed_profile_and_preserves_alias_and_trust() {
    let local = IdentityManager::create().unwrap();
    let peer = IdentityManager::create().unwrap();
    let mut account = AccountCore::new(Some(&local.export_secret()), None).unwrap();
    let original = peer
        .contact_card_with_name("Alice")
        .unwrap()
        .to_json()
        .unwrap();
    account.add_contact(&original, "Work Alice").unwrap();
    account
        .mark_contact_verified(&peer.public_identity().id)
        .unwrap();
    let updated = peer
        .contact_card_with_profile("New Alice", &avatar_header(48))
        .unwrap()
        .to_json()
        .unwrap();
    account.prepare_peer(&updated, true).unwrap();
    let contacts: Vec<ContactRecord> =
        serde_json::from_str(&account.contacts_json().unwrap()).unwrap();
    assert_eq!(contacts[0].card.avatar, avatar_header(48));
    assert_eq!(contacts[0].signed_name, "New Alice");
    assert_eq!(contacts[0].display_name, "Work Alice");
    assert!(contacts[0].verified);
}

#[test]
fn signed_contact_card_verifies_and_has_no_private_material() {
    let identity = IdentityManager::create().expect("identity should generate");
    let card = identity
        .contact_card_with_name("Alice")
        .expect("card should sign");
    let encoded = card.to_json().expect("card should serialize");

    let verified = ContactStore::verify_card(&encoded).expect("card should verify");

    assert_eq!(verified.identity_id, identity.public_identity().id);
    assert_eq!(verified.display_name, "Alice");
    assert!(!encoded.contains(identity.mnemonic()));
    assert_eq!(verified.fingerprint.split('-').count(), 8);
}

#[test]
fn tampered_display_name_is_rejected() {
    let identity = IdentityManager::create().expect("identity should generate");
    let encoded = identity
        .contact_card_with_name("Alice")
        .expect("card should sign")
        .to_json()
        .expect("card should serialize")
        .replace("Alice", "Mallory");

    assert!(matches!(
        ContactStore::verify_card(&encoded),
        Err(ContactError::InvalidSignature)
    ));
}

#[test]
fn tampered_contact_card_is_rejected() {
    let identity = IdentityManager::create().expect("identity should generate");
    let card = identity.contact_card().expect("card should sign");
    let tampered = card
        .to_json()
        .expect("card should serialize")
        .replace("did:cht:", "did:cht:00");

    assert!(matches!(
        ContactStore::verify_card(&tampered),
        Err(ContactError::IdentityMismatch) | Err(ContactError::InvalidSignature)
    ));
}

#[test]
fn contacts_can_be_added_verified_and_removed() {
    let identity = IdentityManager::create().expect("identity should generate");
    let card = identity.contact_card().expect("card should sign");
    let mut contacts = ContactStore::default();

    let contact = contacts
        .add_card(&card.to_json().expect("card should serialize"), "Alice")
        .expect("contact should add");
    assert!(!contact.verified);

    contacts
        .mark_verified(&contact.identity_id)
        .expect("contact should verify");
    assert!(contacts.list()[0].verified);

    contacts
        .remove(&contact.identity_id)
        .expect("contact should remove");
    assert!(contacts.list().is_empty());
}

#[test]
fn contact_alias_can_be_changed_and_cleared_without_losing_signed_name() {
    let identity = IdentityManager::create().expect("identity should generate");
    let card = identity
        .contact_card_with_name("Alice")
        .expect("card should sign");
    let mut contacts = ContactStore::default();
    let contact = contacts
        .add_card(
            &card.to_json().expect("card should serialize"),
            "Work Alice",
        )
        .expect("contact should add");

    assert_eq!(contact.signed_name, "Alice");
    assert_eq!(contact.alias, "Work Alice");
    assert_eq!(contact.display_name, "Work Alice");

    contacts
        .set_alias(&contact.identity_id, "")
        .expect("alias should clear");
    let cleared = contacts.list()[0];
    assert_eq!(cleared.signed_name, "Alice");
    assert!(cleared.alias.is_empty());
    assert_eq!(cleared.display_name, "Alice");
}

#[test]
fn legacy_contact_state_is_migrated_to_signed_name_and_alias() {
    let identity = IdentityManager::create().expect("identity should generate");
    let card = identity
        .contact_card_with_name("Alice")
        .expect("card should sign");
    let mut contacts = ContactStore::default();
    contacts
        .add_card(&card.to_json().expect("card should serialize"), "Friend")
        .expect("contact should add");
    let legacy = contacts
        .to_json()
        .expect("contacts should serialize")
        .replace(",\"signedName\":\"Alice\",\"alias\":\"Friend\"", "");

    let migrated = ContactStore::from_json(&legacy).expect("legacy contacts should migrate");
    let contact = migrated.list()[0];
    assert_eq!(contact.signed_name, "Alice");
    assert_eq!(contact.alias, "Friend");
    assert_eq!(contact.display_name, "Friend");
}

#[test]
fn duplicate_contact_is_rejected() {
    let identity = IdentityManager::create().expect("identity should generate");
    let encoded = identity
        .contact_card()
        .expect("card should sign")
        .to_json()
        .expect("card should serialize");
    let mut contacts = ContactStore::default();
    contacts
        .add_card(&encoded, "Alice")
        .expect("first add should work");

    assert!(matches!(
        contacts.add_card(&encoded, "Alice again"),
        Err(ContactError::AlreadyExists(_))
    ));
}

#[test]
fn account_can_inspect_a_signed_card_without_saving_it() {
    let identity = IdentityManager::create().expect("identity should generate");
    let encoded = identity
        .contact_card()
        .expect("card should sign")
        .to_json()
        .expect("card should serialize");
    let account = AccountCore::new(None, None).expect("account should initialize");

    let inspected: ContactRecord = serde_json::from_str(
        &account
            .inspect_contact_card_json(&encoded)
            .expect("signed card should inspect"),
    )
    .expect("inspection should return a contact record");

    assert_eq!(inspected.identity_id, identity.public_identity().id);
    assert!(!inspected.verified);
    assert_eq!(
        account.contacts_json().expect("contacts should serialize"),
        "[]"
    );
}
