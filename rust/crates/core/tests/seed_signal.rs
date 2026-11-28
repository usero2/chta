use cht_core::{AccountCore, IdentityManager};
use serde_json::{Value, json};

const NOW: u64 = 1_800_000_000_000;
const SESSION: &str = "0123456789abcdef0123456789abcdef";

fn owner(n: u8) -> AccountCore {
    let secret = json!({"derivationVersion":1,"entropy":vec![n;32],"contactToken":vec![n;32]});
    AccountCore::new(Some(secret.to_string().as_bytes()), None).unwrap()
}
fn id(account: &AccountCore) -> String {
    serde_json::from_str::<Value>(&account.identity_json().unwrap()).unwrap()["id"]
        .as_str()
        .unwrap()
        .into()
}
fn trust(a: &mut AccountCore, b: &AccountCore) {
    a.add_contact(&b.contact_card_json().unwrap(), "test")
        .unwrap();
    a.mark_contact_verified(&id(b)).unwrap();
}
fn pair() -> (AccountCore, AccountCore) {
    let (mut a, mut b) = (owner(1), owner(2));
    trust(&mut a, &b);
    trust(&mut b, &a);
    (a, b)
}
fn payload(kind: &str) -> String {
    if kind == "ice" {
        return json!({"v":1,"t":"ice","s":SESSION,"c":"candidate:1 1 UDP 123 192.0.2.1 1234 typ host","m":null,"l":0}).to_string();
    }
    json!({"v":1,"t":kind,"s":SESSION,"d":format!("v=0\r\na=fingerprint:sha-256 {}\r\na=setup:{}\r\n",vec!["AB";32].join(":"),if kind=="offer" {"actpass"} else {"active"})}).to_string()
}
fn message(kind: &str) -> String {
    format!("cht-control-direct-v1-{SESSION}-{kind}-0")
}
fn signed(a: &AccountCore, b: &AccountCore) -> String {
    a.sign_seed_signal(&id(b), &message("offer"), &payload("offer"), NOW)
        .unwrap()
}

#[test]
fn seed_roundtrip_and_replay_rejection() {
    let (a, b) = pair();
    for kind in ["offer", "answer", "ice"] {
        let source = a
            .sign_seed_signal(&id(&b), &message(kind), &payload(kind), NOW)
            .unwrap();
        let inspected: Value =
            serde_json::from_str(&b.inspect_seed_signal(&source, &id(&a), NOW).unwrap()).unwrap();
        assert_eq!(
            inspected,
            json!({"peerId":id(&a),"messageId":message(kind),"text":payload(kind)})
        );
        assert!(b.inspect_seed_signal(&source, &id(&a), NOW).is_err());
    }
}
#[test]
fn seed_locked_unverified_and_wrong_recipient_are_rejected() {
    let (a, b) = pair();
    let source = signed(&a, &b);
    let locked = AccountCore::new(None, None).unwrap();
    assert!(
        locked
            .sign_seed_signal(&id(&b), &message("offer"), &payload("offer"), NOW)
            .is_err()
    );
    assert!(locked.inspect_seed_signal(&source, &id(&a), NOW).is_err());
    let mut unverified = owner(2);
    unverified
        .add_contact(&a.contact_card_json().unwrap(), "")
        .unwrap();
    assert!(
        unverified
            .inspect_seed_signal(&source, &id(&a), NOW)
            .is_err()
    );
    assert!(
        unverified
            .sign_seed_signal(&id(&a), &message("offer"), &payload("offer"), NOW)
            .is_err()
    );
    let mut other = owner(3);
    trust(&mut other, &a);
    assert!(other.inspect_seed_signal(&source, &id(&a), NOW).is_err());
    assert!(b.inspect_seed_signal(&source, &id(&other), NOW).is_err());
    assert!(
        a.sign_seed_signal(&id(&a), &message("offer"), &payload("offer"), NOW)
            .is_err()
    );
}
#[test]
fn seed_tampered_signed_fields_keys_and_extra_fields_are_rejected() {
    let (a, b) = pair();
    let source = signed(&a, &b);
    for (field, value) in [
        ("from", json!(id(&owner(3)))),
        ("to", json!(id(&owner(3)))),
        ("session", json!("f".repeat(32))),
        (
            "id",
            json!(format!("cht-control-direct-v1-{SESSION}-offer-1")),
        ),
        ("kind", json!("answer")),
        ("payload", json!(payload("answer"))),
        ("issuedAt", json!(NOW + 1)),
        ("expiresAt", json!(NOW + 100)),
        ("publicKey", json!("A".repeat(43))),
        ("signature", json!("A".repeat(86))),
        ("extra", json!(true)),
    ] {
        let mut changed: Value = serde_json::from_str(&source).unwrap();
        changed[field] = value;
        assert!(
            b.inspect_seed_signal(&changed.to_string(), &id(&a), NOW)
                .is_err(),
            "{field}"
        );
    }
    // Rejected packets do not consume the legitimate replay ID.
    assert!(b.inspect_seed_signal(&source, &id(&a), NOW).is_ok());
}
#[test]
fn seed_expired_future_unsafe_and_invalid_payload_metadata_are_rejected() {
    let (a, b) = pair();
    let source = signed(&a, &b);
    assert!(
        b.inspect_seed_signal(&source, &id(&a), NOW + 120_000)
            .is_err()
    );
    assert!(
        b.inspect_seed_signal(&source, &id(&a), NOW - 30_001)
            .is_err()
    );
    assert!(
        a.sign_seed_signal(
            &id(&b),
            &message("offer"),
            &payload("offer"),
            9_007_199_254_740_991
        )
        .is_err()
    );
    let original: Value = serde_json::from_str(&payload("offer")).unwrap();
    for (field, value) in [
        ("v", json!(2)),
        ("t", json!("message")),
        ("s", json!("f".repeat(32))),
        ("extra", json!("secret")),
        ("d", json!("v=0\r\n")),
        ("d", json!("x".repeat(11001))),
    ] {
        let mut changed = original.clone();
        changed[field] = value;
        assert!(
            a.sign_seed_signal(&id(&b), &message("offer"), &changed.to_string(), NOW)
                .is_err(),
            "{field}"
        );
    }
    assert!(
        a.sign_seed_signal(&id(&b), &message("offer"), &payload("answer"), NOW)
            .is_err()
    );
    let wrong_role = payload("offer").replace("actpass", "active");
    assert!(
        a.sign_seed_signal(&id(&b), &message("offer"), &wrong_role, NOW)
            .is_err()
    );
    let turn = payload("ice").replace("192.0.2.1", "93.184.216.34").replace("typ host", "typ relay");
    assert!(a.sign_seed_signal(&id(&b), &message("ice"), &turn, NOW).is_ok());
    for candidate in [
        "candidate:1 1 UDP 1 192.0.2.1 12 typ relay",
        "file bytes",
        "",
    ] {
        let mut ice: Value = serde_json::from_str(&payload("ice")).unwrap();
        ice["c"] = json!(candidate);
        assert!(
            a.sign_seed_signal(&id(&b), &message("ice"), &ice.to_string(), NOW)
                .is_err()
        );
    }
    for (field, value) in [
        ("m", json!("x".repeat(65))),
        ("l", json!(-1)),
        ("l", json!(65536)),
        ("extra", json!(1)),
    ] {
        let mut ice: Value = serde_json::from_str(&payload("ice")).unwrap();
        ice[field] = value;
        assert!(
            a.sign_seed_signal(&id(&b), &message("ice"), &ice.to_string(), NOW)
                .is_err()
        );
    }
    for field in ["m", "l"] {
        let mut ice: Value = serde_json::from_str(&payload("ice")).unwrap();
        ice.as_object_mut().unwrap().remove(field);
        assert!(
            a.sign_seed_signal(&id(&b), &message("ice"), &ice.to_string(), NOW)
                .is_err(),
            "missing {field}"
        );
    }
    let large_component = payload("ice").replace("1 UDP", "257 UDP");
    assert!(
        a.sign_seed_signal(&id(&b), &message("ice"), &large_component, NOW)
            .is_err()
    );
}

#[test]
#[ignore = "explicit deterministic shared-fixture generation only"]
fn generate_seed_fixture() {
    let (a, b) = pair();
    let envelope: Value = serde_json::from_str(&signed(&a, &b)).unwrap();
    let signal: cht_core::seed_signal::SeedSignal =
        serde_json::from_value(envelope.clone()).unwrap();
    let fixture = json!({"now":NOW,"envelope":envelope,"canonical":String::from_utf8(signal.signing_payload().unwrap()).unwrap(),"senderPublicKey":signal.public_key,"recipientId":id(&b)});
    let path = std::env::var("CHT_SEED_FIXTURE_OUT").expect("explicit output path");
    std::fs::create_dir_all(std::path::Path::new(&path).parent().unwrap()).unwrap();
    std::fs::write(
        path,
        format!("{}\n", serde_json::to_string_pretty(&fixture).unwrap()),
    )
    .unwrap();
}
#[test]
fn seed_contact_capability_is_signed() {
    let identity = IdentityManager::create().unwrap();
    let card = identity.contact_card().unwrap().to_json().unwrap();
    assert!(card.contains("seed-v1"));
    assert!(cht_core::ContactStore::verify_card(&card.replace("seed-v1", "seed-v2")).is_err());
}

#[test]
fn seed_signature_is_bound_to_stored_verified_contact_key() {
    let (a, b) = pair();
    let source = signed(&a, &b);
    let mut contacts: Value = serde_json::from_str(&b.contacts_state_json().unwrap()).unwrap();
    contacts["contacts"][id(&a)]["card"]["identity"]["rootPublicKey"] = json!("A".repeat(43));
    let synthetic_secret =
        json!({"derivationVersion":1,"entropy":vec![2;32],"contactToken":vec![2;32]}).to_string();
    let recipient = AccountCore::new(
        Some(synthetic_secret.as_bytes()),
        Some(&contacts.to_string()),
    )
    .unwrap();
    assert!(
        recipient
            .inspect_seed_signal(&source, &id(&a), NOW)
            .unwrap_err()
            .contains("verified contact key")
    );
}

#[test]
fn seed_shared_fixture_stays_canonical_and_deterministic() {
    let fixture: Value = serde_json::from_str(include_str!(
        "../../../../apps/web_portal/test/fixtures/seed-signal.json"
    ))
    .unwrap();
    let (a, b) = pair();
    let envelope: Value = serde_json::from_str(&signed(&a, &b)).unwrap();
    assert_eq!(fixture["envelope"], envelope);
    let signal: cht_core::seed_signal::SeedSignal = serde_json::from_value(envelope).unwrap();
    assert_eq!(
        fixture["canonical"],
        String::from_utf8(signal.signing_payload().unwrap()).unwrap()
    );
}
