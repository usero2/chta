use cht_core::WebChatCore;

#[test]
fn deleted_initial_rooms_stay_deleted_after_restart_including_empty_state() {
    let mut core = WebChatCore::new(None).unwrap();
    core.send_text("general", "local history", 42).unwrap();
    core.delete_conversation("general").unwrap();
    let saved = core.export_state_json().unwrap();
    let mut restored = WebChatCore::new(Some(&saved)).unwrap();
    assert!(!restored.snapshot_json().unwrap().contains("general"));
    restored.delete_conversation("design").unwrap();
    let empty = restored.export_state_json().unwrap();
    let mut again = WebChatCore::new(Some(&empty)).unwrap();
    assert_eq!(
        serde_json::from_str::<serde_json::Value>(&again.snapshot_json().unwrap()).unwrap()["conversations"],
        serde_json::json!([])
    );
    assert!(again.delete_conversation("missing").is_err());
    assert_eq!(again.export_state_json().unwrap(), empty);
}

#[test]
fn web_core_seeds_from_rust_when_no_state_is_supplied() {
    let core = WebChatCore::new(None).expect("sample core should initialize");

    assert!(
        core.snapshot_json()
            .expect("snapshot should work")
            .contains("general")
    );
}

#[test]
fn web_core_restores_and_mutates_persisted_state() {
    let original = WebChatCore::new(None).expect("sample core should initialize");
    let state = original.export_state_json().expect("state should export");
    let mut restored = WebChatCore::new(Some(&state)).expect("state should restore");

    let snapshot = restored
        .send_text("general", "  from wasm command  ", 1_700_000_500_000)
        .expect("send should succeed");

    assert!(snapshot.contains("from wasm command"));
    assert!(
        restored
            .export_state_json()
            .expect("state should export")
            .contains("from wasm command")
    );
}

#[test]
fn web_core_rejects_invalid_commands() {
    let mut core = WebChatCore::new(None).expect("sample core should initialize");

    assert!(core.send_text("missing", "hello", 1).is_err());
    assert!(core.send_text("general", "   ", 1).is_err());
}
