use cht_core::{DeviceEngine, IdentityManager};
use serde_json::{Value, json};

const NOW: u64 = 1_800_000_000_000;
const SESSION: &str = "11111111111111111111111111111111";
const OTHER: &str = "22222222222222222222222222222222";

fn call(e: &mut DeviceEngine, root: &IdentityManager, op: &str, args: Value) -> Value {
    e.call(root, op, args).unwrap()
}
fn cert(e: &mut DeviceEngine, root: &IdentityManager) -> Value {
    call(e, root, "local", json!({}))["certificate"].clone()
}
fn connect(a: &mut DeviceEngine, b: &mut DeviceEngine, root: &IdentityManager, session: &str) {
    let ca = cert(a, root);
    let cb = cert(b, root);
    call(
        b,
        root,
        "prepare",
        json!({"certificate":ca,"session":session,"initiator":false}),
    );
    let first = call(
        a,
        root,
        "prepare",
        json!({"certificate":cb,"session":session,"initiator":true}),
    );
    let second = call(
        b,
        root,
        "handshake",
        json!({"session":session,"frame":first["frame"]}),
    );
    assert_eq!(second["ready"], true);
    let done = call(
        a,
        root,
        "handshake",
        json!({"session":session,"frame":second["frame"]}),
    );
    assert_eq!(done["ready"], true);
}

#[test]
fn same_root_distinct_device_keys() {
    let root = IdentityManager::create().unwrap();
    let restored = IdentityManager::restore(root.mnemonic()).unwrap();
    let mut a = DeviceEngine::new(&root, NOW).unwrap();
    let mut b = DeviceEngine::new(&restored, NOW).unwrap();
    let ca = cert(&mut a, &root);
    let cb = cert(&mut b, &restored);
    assert_eq!(ca["ownerId"], root.public_identity().id);
    assert_eq!(ca["ownerId"], cb["ownerId"]);
    for key in ["deviceId", "signingPublicKey", "noisePublicKey"] {
        assert_ne!(ca[key], cb[key]);
    }
    for op in ["export", "exportPrivateState", "secret", "mnemonic"] {
        assert!(a.call(&root, op, json!({})).is_err());
    }
}

#[test]
fn certificate_tampering_and_cross_root_rejected() {
    let root = IdentityManager::create().unwrap();
    let alien = IdentityManager::create().unwrap();
    let mut a = DeviceEngine::new(&root, NOW).unwrap();
    let mut b = DeviceEngine::new(&root, NOW).unwrap();
    let original = cert(&mut a, &root);
    call(
        &mut b,
        &root,
        "inspectCertificate",
        json!({"certificate":original}),
    );
    for (key, replacement) in [
        ("version", json!(2)),
        ("ownerId", json!(alien.public_identity().id)),
        (
            "rootPublicKey",
            json!(alien.public_identity().root_public_key),
        ),
        ("deviceId", json!(OTHER)),
        (
            "signingPublicKey",
            json!(alien.public_identity().root_public_key),
        ),
        (
            "noisePublicKey",
            json!(alien.public_identity().noise_static_public_key),
        ),
        ("createdAt", json!(NOW + 1)),
        ("signature", json!("A".repeat(86))),
    ] {
        let mut changed = original.clone();
        changed[key] = replacement;
        assert!(
            b.call(&root, "inspectCertificate", json!({"certificate":changed}))
                .is_err(),
            "{key}"
        );
    }
    let mut extra = original.clone();
    extra["unexpected"] = json!(true);
    assert!(
        b.call(&root, "inspectCertificate", json!({"certificate":extra}))
            .is_err()
    );
    assert!(b.call(&alien, "local", json!({})).is_err());
    let mut other = DeviceEngine::new(&alien, NOW).unwrap();
    let foreign = cert(&mut other, &alien);
    assert!(
        b.call(
            &root,
            "prepare",
            json!({"certificate":foreign,"session":SESSION,"initiator":true})
        )
        .is_err()
    );
}

#[test]
fn device_signal_cannot_contain_content() {
    let root = IdentityManager::create().unwrap();
    let mut a = DeviceEngine::new(&root, NOW).unwrap();
    let mut b = DeviceEngine::new(&root, NOW).unwrap();
    let ca = cert(&mut a, &root);
    let cb = cert(&mut b, &root);
    let text = json!({"v":1,"t":"ice","s":SESSION,"c":"candidate:1 1 UDP 123 192.0.2.1 1234 typ host","m":null,"l":0}).to_string();
    let id = format!("cht-control-direct-v1-{SESSION}-ice-1");
    let signed = call(
        &mut a,
        &root,
        "signSignal",
        json!({"toDevice":cb["deviceId"],"id":id,"text":text,"now":NOW}),
    );
    let accepted = call(
        &mut b,
        &root,
        "inspectSignal",
        json!({"envelope":signed,"expectedDevice":ca["deviceId"],"now":NOW}),
    );
    assert_eq!(accepted["text"], text);
    assert!(
        b.call(
            &root,
            "inspectSignal",
            json!({"envelope":signed,"expectedDevice":ca["deviceId"],"now":NOW})
        )
        .is_err()
    );
    for packet in [
        json!({"v":1,"t":"message","s":SESSION,"text":"secret"}),
        json!({"v":1,"t":"ice","s":SESSION,"c":"candidate:1 1 UDP 123 192.0.2.1 1234 typ host","m":null,"l":0,"text":"secret"}),
    ] {
        assert!(
            a.call(
                &root,
                "signSignal",
                json!({"toDevice":cb["deviceId"],"id":id,"text":packet.to_string(),"now":NOW})
            )
            .is_err()
        );
    }
}

#[test]
fn device_noise_sessions_are_pair_and_session_bound() {
    let root = IdentityManager::create().unwrap();
    let mut a = DeviceEngine::new(&root, NOW).unwrap();
    let mut b = DeviceEngine::new(&root, NOW).unwrap();
    connect(&mut a, &mut b, &root, SESSION);
    let encrypted = call(
        &mut a,
        &root,
        "seal",
        json!({"session":SESSION,"text":"private fixture"}),
    );
    assert!(
        !encrypted["frame"]
            .as_str()
            .unwrap()
            .contains("private fixture")
    );
    let opened = call(
        &mut b,
        &root,
        "open",
        json!({"session":SESSION,"frame":encrypted["frame"]}),
    );
    assert_eq!(opened["text"], "private fixture");
    assert!(
        b.call(
            &root,
            "open",
            json!({"session":SESSION,"frame":encrypted["frame"]})
        )
        .is_err()
    );
    assert!(
        b.call(
            &root,
            "open",
            json!({"session":OTHER,"frame":encrypted["frame"]})
        )
        .is_err()
    );
    // A failed new probe cannot destroy the authenticated live context.
    let ca = cert(&mut a, &root);
    call(
        &mut b,
        &root,
        "prepare",
        json!({"certificate":ca,"session":OTHER,"initiator":false}),
    );
    assert!(
        b.call(&root, "handshake", json!({"session":OTHER,"frame":"AAAA"}))
            .is_err()
    );
    let next = call(
        &mut a,
        &root,
        "seal",
        json!({"session":SESSION,"text":"still live"}),
    );
    assert_eq!(
        call(
            &mut b,
            &root,
            "open",
            json!({"session":SESSION,"frame":next["frame"]})
        )["text"],
        "still live"
    );
}

#[test]
fn replay_and_wrong_device_rejected() {
    let root = IdentityManager::create().unwrap();
    let mut a = DeviceEngine::new(&root, NOW).unwrap();
    let mut b = DeviceEngine::new(&root, NOW).unwrap();
    let mut c = DeviceEngine::new(&root, NOW).unwrap();
    let cb = cert(&mut b, &root);
    let ca = cert(&mut a, &root);
    call(
        &mut c,
        &root,
        "prepare",
        json!({"certificate":ca,"session":SESSION,"initiator":false}),
    );
    let first = call(
        &mut a,
        &root,
        "prepare",
        json!({"certificate":cb,"session":SESSION,"initiator":true}),
    );
    assert!(
        c.call(
            &root,
            "handshake",
            json!({"session":SESSION,"frame":first["frame"]})
        )
        .is_err()
    );
    assert!(
        a.call(
            &root,
            "prepare",
            json!({"certificate":cb,"session":SESSION,"initiator":true})
        )
        .is_err()
    );
}
