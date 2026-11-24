use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use cht_core::{AccountCore, seed_dispatch::SeedDispatch};
use ed25519_dalek::SigningKey;
use serde_json::{Value, json};

const SEED: &str = "e0ba672185682a830d168e31cee185b9434b49b210a7ec7a435e78fcb2a532a5";
fn envelope() -> Value {
    serde_json::from_str::<Value>(include_str!(
        "../../../../apps/web_portal/test/fixtures/seed-signal.json"
    ))
    .unwrap()["envelope"]
        .clone()
}
fn account() -> AccountCore {
    let secret = json!({"derivationVersion":1,"entropy":vec![1u8;32],"contactToken":vec![1u8;32]});
    AccountCore::new(Some(secret.to_string().as_bytes()), None).unwrap()
}
#[test]
fn dispatch_account_binds_owner_seed_channel_sequence_and_envelope() {
    let a = account();
    let nonce = URL_SAFE_NO_PAD.encode([5u8; 32]);
    let e = envelope();
    let source = a
        .sign_seed_dispatch(SEED, &nonce, 1, &e.to_string())
        .unwrap();
    let p: SeedDispatch = serde_json::from_str(&source).unwrap();
    assert_eq!(p.sequence, 1);
    assert_eq!(p.connection, nonce);
    assert_eq!(p.seed_id, SEED);
    assert_eq!(p.envelope_hash, SeedDispatch::envelope_hash(&e).unwrap());
    for sequence in [0, 9_007_199_254_740_992, u64::MAX] {
        assert!(
            a.sign_seed_dispatch(SEED, &nonce, sequence, &e.to_string())
                .is_err()
        );
    }
    for (seed, channel) in [("bad", nonce.as_str()), (SEED, "bad")] {
        assert!(
            a.sign_seed_dispatch(seed, channel, 1, &e.to_string())
                .is_err()
        );
    }
    let mut wrong = e.clone();
    wrong["from"] = json!(format!("did:cht:{}", "0".repeat(64)));
    assert!(
        a.sign_seed_dispatch(SEED, &nonce, 1, &wrong.to_string())
            .is_err()
    );
    assert!(
        a.sign_seed_dispatch(SEED, &nonce, 1, &" ".repeat(16385))
            .is_err()
    );
    let locked = AccountCore::new(None, None).unwrap();
    assert!(
        locked
            .sign_seed_dispatch(SEED, &nonce, 1, &e.to_string())
            .is_err()
    );
}
#[test]
fn deterministic_dispatch_fixture_agrees_with_js() {
    let f: Value = serde_json::from_str(include_str!(
        "../../../../apps/web_portal/test/fixtures/seed-dispatch.json"
    ))
    .unwrap();
    let p = SeedDispatch::signed(
        &SigningKey::from_bytes(&[7u8; 32]),
        SEED,
        f["proof"]["connection"].as_str().unwrap(),
        1,
        &f["envelope"],
    )
    .unwrap();
    assert_eq!(serde_json::to_value(&p).unwrap(), f["proof"]);
    assert_eq!(
        String::from_utf8(p.signing_payload().unwrap()).unwrap(),
        f["canonical"]
    );
    let mut reordered = f["envelope"].clone();
    reordered["payload"] = json!("changed");
    assert_ne!(
        SeedDispatch::envelope_hash(&reordered).unwrap(),
        p.envelope_hash
    );
}
