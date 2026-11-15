use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::ChatError;

const STATE_SCHEMA_VERSION: u32 = 1;

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct ConversationId(String);

impl ConversationId {
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl TryFrom<&str> for ConversationId {
    type Error = ChatError;

    fn try_from(value: &str) -> Result<Self, Self::Error> {
        let valid = !value.is_empty()
            && value.split('-').all(|segment| {
                !segment.is_empty()
                    && segment
                        .bytes()
                        .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit())
            });

        if valid {
            Ok(Self(value.to_owned()))
        } else {
            Err(ChatError::InvalidId(value.to_owned()))
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct MessageId(u64);

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ChatMessage {
    pub id: MessageId,
    pub text: String,
    pub sent_at_ms: i64,
    pub incoming: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConversationSummary {
    pub id: ConversationId,
    pub title: String,
    pub preview: String,
    pub updated_at_ms: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Conversation {
    pub id: ConversationId,
    pub title: String,
    pub messages: Vec<ChatMessage>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ChatStore {
    summaries: Vec<ConversationSummary>,
    conversations: BTreeMap<ConversationId, Conversation>,
    next_message_id: u64,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct StateDocument {
    schema_version: u32,
    next_message_id: u64,
    conversations: Vec<ConversationDocument>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct SnapshotDocument<'a> {
    schema_version: u32,
    conversations: &'a [ConversationDocument],
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ConversationDocument {
    id: String,
    title: String,
    preview: String,
    updated_at_milliseconds: i64,
    messages: Vec<MessageDocument>,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct MessageDocument {
    id: u64,
    text: String,
    sent_at_milliseconds: i64,
    incoming: bool,
}

impl ChatStore {
    pub fn sample() -> Self {
        let general = ConversationId::try_from("general").expect("static id is valid");
        let design = ConversationId::try_from("design").expect("static id is valid");

        let summaries = vec![
            ConversationSummary {
                id: general.clone(),
                title: "General".to_owned(),
                preview: "Web-first foundation".to_owned(),
                updated_at_ms: 1_700_000_000_000,
            },
            ConversationSummary {
                id: design.clone(),
                title: "Design".to_owned(),
                preview: "Adapt the chat experience".to_owned(),
                updated_at_ms: 1_699_999_900_000,
            },
        ];

        let conversations = BTreeMap::from([
            (
                general.clone(),
                Conversation {
                    id: general,
                    title: "General".to_owned(),
                    messages: vec![ChatMessage {
                        id: MessageId(1),
                        text: "Web-first foundation".to_owned(),
                        sent_at_ms: 1_700_000_000_000,
                        incoming: true,
                    }],
                },
            ),
            (
                design.clone(),
                Conversation {
                    id: design,
                    title: "Design".to_owned(),
                    messages: vec![ChatMessage {
                        id: MessageId(2),
                        text: "Adapt the chat experience".to_owned(),
                        sent_at_ms: 1_699_999_900_000,
                        incoming: true,
                    }],
                },
            ),
        ]);

        Self {
            summaries,
            conversations,
            next_message_id: 3,
        }
    }

    pub fn conversations(&self) -> &[ConversationSummary] {
        &self.summaries
    }

    pub fn from_persisted_json(json: &str) -> Result<Self, ChatError> {
        let document: StateDocument = serde_json::from_str(json)
            .map_err(|error| ChatError::InvalidState(error.to_string()))?;
        if document.schema_version != STATE_SCHEMA_VERSION {
            return Err(ChatError::UnsupportedSchema(document.schema_version));
        }

        let mut summaries = Vec::with_capacity(document.conversations.len());
        let mut conversations = BTreeMap::new();
        let mut message_ids = std::collections::BTreeSet::new();
        let mut highest_message_id = 0;

        for item in document.conversations {
            let id = ConversationId::try_from(item.id.as_str())?;
            if item.title.trim().is_empty() {
                return Err(ChatError::InvalidState(format!(
                    "conversation {} has an empty title",
                    id.as_str()
                )));
            }

            let mut messages = Vec::with_capacity(item.messages.len());
            for message in item.messages {
                if message.id == 0 || !message_ids.insert(message.id) {
                    return Err(ChatError::InvalidState(format!(
                        "message id {} is invalid or duplicated",
                        message.id
                    )));
                }
                highest_message_id = highest_message_id.max(message.id);
                messages.push(ChatMessage {
                    id: MessageId(message.id),
                    text: message.text,
                    sent_at_ms: message.sent_at_milliseconds,
                    incoming: message.incoming,
                });
            }
            messages.sort_by_key(|message| (message.sent_at_ms, message.id));

            summaries.push(ConversationSummary {
                id: id.clone(),
                title: item.title.clone(),
                preview: item.preview,
                updated_at_ms: item.updated_at_milliseconds,
            });
            if conversations
                .insert(
                    id.clone(),
                    Conversation {
                        id,
                        title: item.title,
                        messages,
                    },
                )
                .is_some()
            {
                return Err(ChatError::InvalidState(format!(
                    "duplicate conversation id: {}",
                    item.id
                )));
            }
        }

        if document.next_message_id == 0 || document.next_message_id <= highest_message_id {
            return Err(ChatError::InvalidState(
                "nextMessageId must be greater than every stored message id".to_owned(),
            ));
        }

        summaries.sort_by(|left, right| {
            right
                .updated_at_ms
                .cmp(&left.updated_at_ms)
                .then(left.id.cmp(&right.id))
        });
        Ok(Self {
            summaries,
            conversations,
            next_message_id: document.next_message_id,
        })
    }

    pub fn to_persisted_json(&self) -> Result<String, ChatError> {
        serde_json::to_string(&StateDocument {
            schema_version: STATE_SCHEMA_VERSION,
            next_message_id: self.next_message_id,
            conversations: self.conversation_documents()?,
        })
        .map_err(|error| ChatError::InvalidState(error.to_string()))
    }

    pub fn snapshot_json(&self) -> Result<String, ChatError> {
        let conversations = self.conversation_documents()?;
        serde_json::to_string(&SnapshotDocument {
            schema_version: STATE_SCHEMA_VERSION,
            conversations: &conversations,
        })
        .map_err(|error| ChatError::InvalidState(error.to_string()))
    }

    pub fn conversation(&self, id: &ConversationId) -> Result<&Conversation, ChatError> {
        self.conversations
            .get(id)
            .ok_or_else(|| ChatError::ConversationNotFound(id.as_str().to_owned()))
    }

    pub fn send_text(
        &mut self,
        id: &ConversationId,
        text: &str,
        sent_at_ms: i64,
    ) -> Result<ChatMessage, ChatError> {
        let text = text.trim();
        if text.is_empty() {
            return Err(ChatError::EmptyMessage);
        }

        let conversation = self
            .conversations
            .get_mut(id)
            .ok_or_else(|| ChatError::ConversationNotFound(id.as_str().to_owned()))?;
        let message = ChatMessage {
            id: MessageId(self.next_message_id),
            text: text.to_owned(),
            sent_at_ms,
            incoming: false,
        };
        self.next_message_id += 1;
        conversation.messages.push(message.clone());
        conversation
            .messages
            .sort_by_key(|item| (item.sent_at_ms, item.id));

        if let Some(summary) = self.summaries.iter_mut().find(|item| item.id == *id) {
            summary.preview.clone_from(&message.text);
            summary.updated_at_ms = sent_at_ms;
        }
        self.summaries.sort_by(|left, right| {
            right
                .updated_at_ms
                .cmp(&left.updated_at_ms)
                .then(left.id.cmp(&right.id))
        });

        Ok(message)
    }

    pub fn delete_conversation(&mut self, id: &ConversationId) -> Result<(), ChatError> {
        self.conversations
            .remove(id)
            .ok_or_else(|| ChatError::ConversationNotFound(id.as_str().to_owned()))?;
        self.summaries.retain(|summary| summary.id != *id);
        Ok(())
    }

    fn conversation_documents(&self) -> Result<Vec<ConversationDocument>, ChatError> {
        self.summaries
            .iter()
            .map(|summary| {
                let conversation = self.conversation(&summary.id)?;
                Ok(ConversationDocument {
                    id: summary.id.as_str().to_owned(),
                    title: summary.title.clone(),
                    preview: summary.preview.clone(),
                    updated_at_milliseconds: summary.updated_at_ms,
                    messages: conversation
                        .messages
                        .iter()
                        .map(|message| MessageDocument {
                            id: message.id.0,
                            text: message.text.clone(),
                            sent_at_milliseconds: message.sent_at_ms,
                            incoming: message.incoming,
                        })
                        .collect(),
                })
            })
            .collect()
    }
}
