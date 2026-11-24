use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD as B64};
use cht_core::AccountCore;
use serde_json::{Value, json};
const NOW: u64 = 1800000000000;
#[test]
fn courier_advertisements_are_verifiable_by_independent_relays_without_contact_keys() {
    let a = owner(1);
    let node = a
        .delivery_call("nodeCertificate", json!({"now":NOW}))
        .unwrap();
    let ad=a.delivery_call("signControl",json!({"nodeState":node["state"],"kind":"advertisement","challenge":B64.encode([0u8;32]),"body":{"version":1,"nodeId":node["certificate"]["nodeId"],"ownerId":node["certificate"]["ownerId"],"routes":["wss://relay.example.com/cht"],"maxPackageBytes":262144,"freeBytes":1073741824u64},"now":NOW,"expiresAt":NOW+900000})).unwrap();
    cht_relay_protocol::verify_courier_advertisement(&ad, NOW, false).unwrap();
    let mut bad = ad.clone();
    bad["body"]["freeBytes"] = json!(1);
    assert!(cht_relay_protocol::verify_courier_advertisement(&bad, NOW, false).is_err());
}
#[test]
#[ignore = "explicit disposable native/Wasm interop fixture generation only"]
fn export_courier_fixture() {
    let (a, b) = pair();
    let (envelope, parts, proofs) = sealed(&a, &b);
    let opened = b
        .delivery_call(
            "openManifest",
            json!({"manifest":envelope["manifest"],"now":NOW}),
        )
        .unwrap();
    let receipt=b.delivery_call("signControl",json!({"kind":"receipt","challenge":opened["receiptChallenge"],"body":{"jobId":opened["jobId"],"messageId":opened["event"]["messageId"],"manifestHash":opened["manifestHash"],"receivedAt":NOW},"now":NOW,"expiresAt":NOW+60000})).unwrap();
    let event_args = json!({"scope":"direct:test","messageId":"native-wasm","sentAt":NOW,"kind":"text","payload":"cross-target fixture"});
    let event = a.delivery_call("signEvent", event_args.clone()).unwrap();
    let node = a
        .delivery_call("nodeCertificate", json!({"now":NOW}))
        .unwrap();
    let control=a.delivery_call("signControl",json!({"nodeState":node["state"],"kind":"stored","challenge":B64.encode([5u8;32]),"body":{"jobId":"a".repeat(32),"index":0,"hash":"b".repeat(64)},"now":NOW,"expiresAt":NOW+60000})).unwrap();
    let path = std::env::var_os("CHTA_QA_COURIER_FIXTURE")
        .expect("explicit private fixture destination required");
    std::fs::write(path,serde_json::to_vec(&json!({"now":NOW,"envelope":envelope,"parts":parts,"proofs":proofs,"senderContacts":a.contacts_state_json().unwrap(),"recipientContacts":b.contacts_state_json().unwrap(),"eventArgs":event_args,"event":event,"node":node,"control":control,"receipt":receipt,"receiptSigner":id(&b)})).unwrap()).unwrap();
}
#[test]
fn mailbox_survives_recovery_token_rotation_and_pickup_requires_root_possession() {
    let a = owner(1);
    let recovered = AccountCore::new(
        Some(
            json!({"derivationVersion":1,"entropy":vec![1u8;32],"contactToken":vec![99u8;32]})
                .to_string()
                .as_bytes(),
        ),
        None,
    )
    .unwrap();
    let bucket = NOW / 86400000;
    assert_eq!(
        a.delivery_call("mailbox", json!({"bucket":bucket}))
            .unwrap(),
        recovered
            .delivery_call("mailbox", json!({"bucket":bucket}))
            .unwrap()
    );
    let control=a.delivery_call("signControl",json!({"kind":"pickup","body":{"bucket":bucket},"challenge":B64.encode([3u8;32]),"now":NOW,"expiresAt":NOW+60000})).unwrap();
    let args = json!({"control":control,"expectedSigner":id(&a),"challenge":B64.encode([3u8;32]),"now":NOW});
    owner(2)
        .delivery_call("verifyControl", args.clone())
        .unwrap();
    let mut bad = args;
    bad["control"]["body"]["mailbox"] = json!("0".repeat(64));
    assert!(owner(2).delivery_call("verifyControl", bad).is_err());
}
#[test]
fn recipient_receipts_remain_verifiable_after_transport_expiry_without_rewriting_received_time() {
    let a = owner(1);
    let b = owner(2);
    let challenge = B64.encode([7u8; 32]);
    let receipt=a.delivery_call("signControl",json!({"kind":"receipt","challenge":challenge,"body":{"jobId":"a".repeat(32),"messageId":"original","manifestHash":"b".repeat(64),"receivedAt":NOW},"now":NOW,"expiresAt":NOW+60000})).unwrap();
    let value=b.delivery_call("verifyControl",json!({"control":receipt,"expectedSigner":id(&a),"challenge":challenge,"now":NOW+86400000})).unwrap();
    assert_eq!(value["body"]["receivedAt"], NOW);
}
#[test]
fn carriers_validate_only_public_manifest_and_ciphertext_proofs_without_recipient_keys() {
    let (a, b) = pair();
    let (s, parts, proofs) = sealed(&a, &b);
    let carrier = owner(3);
    let m = carrier
        .delivery_call(
            "inspectManifest",
            json!({"manifest":s["manifest"],"now":NOW}),
        )
        .unwrap();
    assert_eq!(m["manifestHash"], s["manifestHash"]);
    let args = json!({"index":0,"count":2,"ciphertext":parts[0]["ciphertext"],"hash":parts[0]["hash"],"root":proofs[0]["root"],"proof":proofs[0]["proof"]});
    assert_eq!(
        carrier
            .delivery_call("verifyPackage", args.clone())
            .unwrap()["bytes"],
        43
    );
    for (field, value) in [
        ("index", json!(1)),
        ("root", json!("0".repeat(64))),
        ("hash", json!("0".repeat(64))),
        ("count", json!(3)),
    ] {
        let mut bad = args.clone();
        bad[field] = value;
        assert!(carrier.delivery_call("verifyPackage", bad).is_err());
    }
    let opened = b
        .delivery_call("openManifest", json!({"manifest":s["manifest"],"now":NOW}))
        .unwrap();
    assert_eq!(opened["bucket"], NOW / 86400000);
}
fn owner(n: u8) -> AccountCore {
    AccountCore::new(
        Some(
            json!({"derivationVersion":1,"entropy":vec![n;32],"contactToken":vec![n;32]})
                .to_string()
                .as_bytes(),
        ),
        None,
    )
    .unwrap()
}
fn id(a: &AccountCore) -> String {
    serde_json::from_str::<Value>(&a.identity_json().unwrap()).unwrap()["id"]
        .as_str()
        .unwrap()
        .into()
}
fn pair() -> (AccountCore, AccountCore) {
    let (mut a, mut b) = (owner(1), owner(2));
    a.add_contact(&b.contact_card_json().unwrap(), "").unwrap();
    a.mark_contact_verified(&id(&b)).unwrap();
    b.add_contact(&a.contact_card_json().unwrap(), "").unwrap();
    b.mark_contact_verified(&id(&a)).unwrap();
    (a, b)
}
fn job(a: &AccountCore, b: &AccountCore) -> Value {
    a.delivery_call("newJob",json!({"peerId":id(b),"jobId":"a".repeat(32),"scope":"direct:test","count":2,"now":NOW,"expiresAt":NOW+86400000})).unwrap()
}
fn part(a: &AccountCore, j: &Value, index: u32) -> Value {
    a.delivery_call(
        "encryptPackage",
        json!({"state":j["state"],"index":index,"plaintext":B64.encode(b"abc"),"now":NOW}),
    )
    .unwrap()
}
fn sealed(a: &AccountCore, b: &AccountCore) -> (Value, Vec<Value>, Vec<Value>) {
    sealed_scope(a, b, "direct:test")
}
fn sealed_scope(a: &AccountCore, b: &AccountCore, scope: &str) -> (Value, Vec<Value>, Vec<Value>) {
    let j = a.delivery_call("newJob",json!({"peerId":id(b),"jobId":"a".repeat(32),"scope":scope,"count":2,"now":NOW,"expiresAt":NOW+86400000})).unwrap();
    let parts = vec![part(a, &j, 0), part(a, &j, 1)];
    let hashes: Vec<_> = parts.iter().map(|p| p["hash"].clone()).collect();
    let proofs: Vec<_> = (0..2)
        .map(|index| {
            a.delivery_call("packageRoot", json!({"hashes":hashes,"index":index}))
                .unwrap()
        })
        .collect();
    let event=a.delivery_call("signEvent",json!({"scope":scope,"messageId":"original-file","sentAt":NOW,"kind":"file","payload":"immutable logical file metadata"})).unwrap();
    let envelope=a.delivery_call("sealManifest",json!({"state":j["state"],"event":event,"metadata":{"size":6,"contentHash":"b".repeat(64),"merkleRoot":proofs[0]["root"],"name":"private.bin","mime":"application/octet-stream"},"now":NOW})).unwrap();
    (envelope, parts, proofs)
}
#[test]
fn group_courier_uses_signed_roster_pins_and_checks_current_and_historical_membership() {
    let (mut a, mut b) = pair();
    let initial = a
        .group_call("create", json!({"name":"team","displayName":"A","now":NOW}))
        .unwrap();
    let gid = serde_json::from_str::<Value>(initial["state"].as_str().unwrap()).unwrap()["groupId"]
        .as_str()
        .unwrap()
        .to_owned();
    let invite = a
        .group_call("invite", json!({"groupId":gid,"peerId":id(&b),"now":NOW}))
        .unwrap();
    let receipt = b
        .group_call(
            "accept",
            json!({"invite":invite["invite"],"displayName":"B","now":NOW}),
        )
        .unwrap();
    let added = a
        .group_call("add", json!({"receipt":receipt["receipt"],"now":NOW}))
        .unwrap();
    b.group_call("apply", json!({"state":added["state"]}))
        .unwrap();
    let epoch = serde_json::from_str::<Value>(added["state"].as_str().unwrap()).unwrap()["epoch"]
        .as_u64()
        .unwrap();
    let scope = format!("{gid}:{epoch}");
    a.remove_contact(&id(&b)).unwrap();
    b.remove_contact(&id(&a)).unwrap();
    let (manifest, parts, proofs) = sealed_scope(&a, &b, &scope);
    let opened = b
        .delivery_call(
            "openManifest",
            json!({"manifest":manifest["manifest"],"now":NOW}),
        )
        .unwrap();
    let args = json!({"state":opened["state"],"index":0,"ciphertext":parts[0]["ciphertext"],"proof":proofs[0]["proof"],"now":NOW});
    b.delivery_call("decryptPackage", args.clone()).unwrap();
    let removed = a
        .group_call("remove", json!({"groupId":gid,"peerId":id(&b),"now":NOW+1}))
        .unwrap();
    b.group_call("apply", json!({"state":removed["state"]}))
        .unwrap();
    assert!(
        b.delivery_call(
            "openManifest",
            json!({"manifest":manifest["manifest"],"now":NOW+1})
        )
        .is_err()
    );
    assert!(b.delivery_call("decryptPackage", args).is_err());
    assert!(a.delivery_call("newJob",json!({"peerId":id(&b),"jobId":"b".repeat(32),"scope":scope,"count":2,"now":NOW+1,"expiresAt":NOW+86400000})).is_err());
}
#[test]
fn sealed_packages_roundtrip_without_exposing_keys_or_plaintext_to_carriers() {
    let (a, b) = pair();
    let (s, parts, proofs) = sealed(&a, &b);
    let carrier = s.to_string();
    assert!(!carrier.contains("private.bin"));
    assert!(!carrier.contains("immutable logical"));
    assert_eq!(s["manifest"].as_object().unwrap().len(), 5);
    assert!(s.get("key").is_none());
    assert!(!carrier.contains(&id(&b)));
    let opened = b
        .delivery_call("openManifest", json!({"manifest":s["manifest"],"now":NOW}))
        .unwrap();
    assert_eq!(opened["event"]["messageId"], "original-file");
    assert_eq!(opened["metadata"]["name"], "private.bin");
    for index in 0..2 {
        let plain=b.delivery_call("decryptPackage",json!({"state":opened["state"],"index":index,"ciphertext":parts[index]["ciphertext"],"proof":proofs[index]["proof"],"now":NOW})).unwrap();
        assert_eq!(plain["plaintext"], B64.encode(b"abc"));
    }
    assert!(
        owner(3)
            .delivery_call("openManifest", json!({"manifest":s["manifest"],"now":NOW}))
            .is_err()
    );
    let other = owner(2);
    assert!(
        other
            .delivery_call("openManifest", json!({"manifest":s["manifest"],"now":NOW}))
            .is_err(),
        "unknown author needs trust"
    );
}
#[test]
fn tamper_truncate_index_expiry_state_and_nonce_injection_are_rejected() {
    let (a, b) = pair();
    let j = job(&a, &b);
    let one = part(&a, &j, 0);
    assert_ne!(
        one["hash"],
        part(&a, &j, 0)["hash"],
        "fresh random nonces even on retry"
    );
    assert_ne!(
        one["hash"],
        part(&a, &job(&a, &b), 0)["hash"],
        "fresh job keys"
    );
    let (s, parts, proofs) = sealed(&a, &b);
    let opened = b
        .delivery_call("openManifest", json!({"manifest":s["manifest"],"now":NOW}))
        .unwrap();
    let args = json!({"state":opened["state"],"index":0,"ciphertext":parts[0]["ciphertext"],"proof":proofs[0]["proof"],"now":NOW});
    for (field, value) in [
        ("index", json!(1)),
        ("ciphertext", json!("AAAA")),
        ("now", json!(NOW + 86400001)),
        ("state", j["state"].clone()),
        ("nonce", json!("A".repeat(32))),
    ] {
        let mut bad = args.clone();
        bad[field] = value;
        assert!(b.delivery_call("decryptPackage", bad).is_err());
    }
    assert!(
        a.delivery_call(
            "encryptPackage",
            json!({"state":j["state"],"index":0,"plaintext":B64.encode(vec![0u8;262145]),"now":NOW})
        )
        .is_err()
    );
    let mut bad = s["manifest"].clone();
    bad["jobId"] = json!("c".repeat(32));
    assert!(
        b.delivery_call("openManifest", json!({"manifest":bad,"now":NOW}))
            .is_err()
    );
}
#[test]
fn node_certificates_survive_protected_restore_and_controls_bind_challenge_and_role() {
    let a = owner(1);
    let b = owner(2);
    let node = a
        .delivery_call("nodeCertificate", json!({"now":NOW}))
        .unwrap();
    let restored = a
        .delivery_call("nodeCertificate", json!({"now":NOW,"state":node["state"]}))
        .unwrap();
    assert_eq!(node["certificate"], restored["certificate"]);
    assert_ne!(
        node["certificate"]["nodeId"],
        a.delivery_call("nodeCertificate", json!({"now":NOW}))
            .unwrap()["certificate"]["nodeId"]
    );
    assert!(
        b.delivery_call("nodeCertificate", json!({"now":NOW,"state":node["state"]}))
            .is_err()
    );
    b.delivery_call(
        "verifyNode",
        json!({"certificate":node["certificate"],"now":NOW}),
    )
    .unwrap();
    let mut bad = node["certificate"].clone();
    bad["nodeId"] = json!("0".repeat(64));
    assert!(
        b.delivery_call("verifyNode", json!({"certificate":bad,"now":NOW}))
            .is_err()
    );
    let control=a.delivery_call("signControl",json!({"nodeState":node["state"],"kind":"stored","challenge":B64.encode([5u8;32]),"body":{"jobId":"a".repeat(32),"index":0,"hash":"b".repeat(64)},"now":NOW,"expiresAt":NOW+60000})).unwrap();
    let args = json!({"control":control,"expectedSigner":node["certificate"]["nodeId"],"challenge":B64.encode([5u8;32]),"now":NOW});
    b.delivery_call("verifyControl", args.clone()).unwrap();
    for (field, value) in [
        ("challenge", json!(B64.encode([6u8; 32]))),
        ("expectedSigner", json!(id(&a))),
        ("now", json!(NOW + 60001)),
    ] {
        let mut bad = args.clone();
        bad[field] = value;
        assert!(b.delivery_call("verifyControl", bad).is_err());
    }
    let mut bad = args;
    bad["control"]["body"]["index"] = json!(1);
    assert!(b.delivery_call("verifyControl", bad).is_err());
}
