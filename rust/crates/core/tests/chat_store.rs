use cht_core::{ChatError, ChatStore, ConversationId};

#[test]
fn sample_conversations_are_deterministic() {
    let store = ChatStore::sample();

    let actual = store
        .conversations()
        .iter()
        .map(|conversation| {
            (
                conversation.id.as_str(),
                conversation.title.as_str(),
                conversation.preview.as_str(),
            )
        })
        .collect::<Vec<_>>();

    assert_eq!(
        actual,
        vec![
            ("general", "General", "Web-first foundation"),
            ("design", "Design", "Adapt the chat experience"),
        ]
    );
}

#[test]
fn unknown_conversation_returns_an_explicit_error() {
    let store = ChatStore::sample();
    let missing = ConversationId::try_from("missing").expect("valid test id");

    assert_eq!(
        store.conversation(&missing),
        Err(ChatError::ConversationNotFound("missing".to_owned()))
    );
}

#[test]
fn send_text_trims_the_message() {
    let mut store = ChatStore::sample();
    let general = ConversationId::try_from("general").expect("valid test id");

    let sent = store
        .send_text(&general, "  hello from cht  ", 1_700_000_100_000)
        .expect("message should be accepted");

    assert_eq!(sent.text, "hello from cht");
    assert_eq!(sent.sent_at_ms, 1_700_000_100_000);
    assert!(!sent.incoming);
}

#[test]
fn whitespace_only_message_is_rejected() {
    let mut store = ChatStore::sample();
    let general = ConversationId::try_from("general").expect("valid test id");

    assert_eq!(
        store.send_text(&general, " \n\t ", 1_700_000_100_000),
        Err(ChatError::EmptyMessage)
    );
}

#[test]
fn equal_timestamps_are_ordered_by_message_id() {
    let mut store = ChatStore::sample();
    let general = ConversationId::try_from("general").expect("valid test id");

    let first = store
        .send_text(&general, "first", 1_700_000_200_000)
        .expect("first message should be accepted");
    let second = store
        .send_text(&general, "second", 1_700_000_200_000)
        .expect("second message should be accepted");

    let conversation = store
        .conversation(&general)
        .expect("sample conversation should exist");
    let tail = &conversation.messages[conversation.messages.len() - 2..];

    assert_eq!(tail[0].id, first.id);
    assert_eq!(tail[1].id, second.id);
    assert!(first.id < second.id);
}

#[test]
fn malformed_conversation_ids_are_rejected() {
    for malformed in ["-", "leading-", "-trailing", "two--hyphens"] {
        assert_eq!(
            ConversationId::try_from(malformed),
            Err(ChatError::InvalidId(malformed.to_owned())),
            "{malformed} should not be accepted",
        );
    }
}
