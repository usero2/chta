mod account;
#[cfg(all(
    not(target_arch = "wasm32"),
    any(target_os = "android", target_os = "linux", target_os = "macos", test)
))]
mod android_storage;
mod chat;
mod contact_requests;
mod contacts;
mod courier;
mod delivery;
#[cfg(not(target_arch = "wasm32"))]
mod desktop_vault;
pub mod device_sync;
mod error;
mod groups;
mod groups_signal;
mod identity;
#[cfg(not(target_arch = "wasm32"))]
mod native;
mod secure_session;
pub mod seed_dispatch;
pub mod seed_signal;
pub use cht_relay_protocol as relay_directory;
mod wasm;

pub use account::{AccountCore, AccountError};
pub use chat::{
    ChatMessage, ChatStore, Conversation, ConversationId, ConversationSummary, MessageId,
};
pub use contacts::{ContactCard, ContactError, ContactRecord, ContactStore};
pub use device_sync::{DeviceCertificate, DeviceEngine};
pub use error::ChatError;
pub use identity::{IdentityError, IdentityManager, PublicIdentity};
pub use secure_session::{DecryptedMessage, SecureSession, SessionError};
pub use wasm::{WebChatCore, core_version};
