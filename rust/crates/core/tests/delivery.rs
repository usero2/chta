use cht_core::AccountCore;
use serde_json::{Value, json};
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
#[test]
fn immutable_delivery_event_verifies_original_author_scope_payload_and_time() {
    let a = owner(1);
    let b = owner(2);
    let event=a.delivery_call("signEvent",json!({"scope":"direct:test","messageId":"original-id","sentAt":1800000000000u64,"kind":"text","payload":"hello"})).unwrap();
    let args = json!({"event":event,"expectedAuthor":id(&a),"scope":"direct:test","payload":"hello","now":1800000000000u64});
    assert_eq!(
        b.delivery_call("verifyEvent", args.clone()).unwrap()["messageId"],
        "original-id"
    );
    for (field, value) in [
        ("expectedAuthor", json!(id(&b))),
        ("scope", json!("group:other")),
        ("payload", json!("changed")),
    ] {
        let mut bad = args.clone();
        bad[field] = value;
        assert!(b.delivery_call("verifyEvent", bad).is_err());
    }
    for (field, value) in [
        ("messageId", json!("changed")),
        ("sentAt", json!(1)),
        ("publicKey", json!("A".repeat(43))),
        ("extra", json!(true)),
    ] {
        let mut bad = args.clone();
        bad["event"][field] = value;
        assert!(b.delivery_call("verifyEvent", bad).is_err());
    }
    assert!(a.delivery_call("signEvent",json!({"scope":"direct:test","messageId":"original-id","sentAt":9007199254740992u64,"kind":"text","payload":"hello"})).is_err());
    assert!(
        AccountCore::new(None, None)
            .unwrap()
            .delivery_call("signEvent", json!({}))
            .is_err()
    );
}
