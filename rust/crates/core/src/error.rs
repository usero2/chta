#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ChatError {
    EmptyMessage,
    InvalidId(String),
    ConversationNotFound(String),
    InvalidState(String),
    UnsupportedSchema(u32),
}

impl std::fmt::Display for ChatError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::EmptyMessage => formatter.write_str("message cannot be empty"),
            Self::InvalidId(value) => write!(formatter, "invalid identifier: {value}"),
            Self::ConversationNotFound(value) => {
                write!(formatter, "conversation not found: {value}")
            }
            Self::InvalidState(value) => write!(formatter, "invalid persisted state: {value}"),
            Self::UnsupportedSchema(version) => {
                write!(formatter, "unsupported persisted state schema: {version}")
            }
        }
    }
}

impl std::error::Error for ChatError {}
