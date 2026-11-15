use cht_core::{ChatError, ChatStore, ConversationId};

#[test]
fn persisted_state_round_trips_messages_and_next_id() {
    let mut store = ChatStore::sample();
    let general = ConversationId::try_from("general").expect("valid test id");
    let first = store
        .send_text(&general, "persist me", 1_700_000_300_000)
        .expect("message should be accepted");

    let json = store.to_persisted_json().expect("state should serialize");
    let mut restored = ChatStore::from_persisted_json(&json).expect("state should restore");
    let second = restored
        .send_text(&general, "after restore", 1_700_000_400_000)
        .expect("restored store should accept messages");

    assert!(second.id > first.id);
    assert_eq!(
        restored
            .conversation(&general)
            .expect("conversation should exist")
            .messages
            .last()
            .expect("message should exist")
            .text,
        "after restore"
    );
}

#[test]
fn snapshot_is_a_ui_projection_without_internal_counter() {
    let json = ChatStore::sample()
        .snapshot_json()
        .expect("snapshot should serialize");
    let snapshot: serde_json::Value = serde_json::from_str(&json).expect("valid JSON");

    assert_eq!(snapshot["schemaVersion"], 1);
    assert_eq!(snapshot["conversations"][0]["id"], "general");
    assert_eq!(
        snapshot["conversations"][0]["messages"][0]["text"],
        "Web-first foundation"
    );
    assert!(snapshot.get("nextMessageId").is_none());
}

#[test]
fn malformed_json_is_rejected_explicitly() {
    assert!(matches!(
        ChatStore::from_persisted_json("not-json"),
        Err(ChatError::InvalidState(_))
    ));
}

#[test]
fn unsupported_schema_is_rejected_explicitly() {
    let json = r#"{"schemaVersion":99,"nextMessageId":1,"conversations":[]}"#;

    assert_eq!(
        ChatStore::from_persisted_json(json),
        Err(ChatError::UnsupportedSchema(99))
    );
}

#[test]
fn invalid_ids_in_persisted_state_do_not_bypass_validation() {
    let valid = ChatStore::sample()
        .to_persisted_json()
        .expect("state should serialize");
    let invalid = valid.replace("\"general\"", "\"General!\"");

    assert!(matches!(
        ChatStore::from_persisted_json(&invalid),
        Err(ChatError::InvalidId(value)) if value == "General!"
    ));
}
