use std::{
    fs,
    io::{Read, Write},
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};

use argon2::{Algorithm, Argon2, Params, Version};
use base64::{Engine as _, engine::general_purpose::STANDARD};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
#[cfg(any(target_os = "android", test))]
use zeroize::Zeroize;
use zeroize::Zeroizing;

const VERSION: u32 = 1;
pub(crate) const MAX_ATTACHMENT_BYTES: usize = 100 * 1024 * 1024;

#[derive(Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct DesktopProfile {
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub avatar: Option<String>,
    #[serde(default)]
    pub contact_avatar: String,
}

#[derive(Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct AccountData {
    pub contacts: Option<String>,
    pub chat: Option<String>,
    #[serde(default)]
    pub profile: DesktopProfile,
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct SavedIdentity {
    pub identity_id: String,
    pub display_name: String,
    pub avatar: String,
    pub locked_until_milliseconds: u64,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct VaultEntry {
    version: u32,
    identity: SavedIdentity,
    salt: String,
    protected_secret: String,
    failed_attempts: u32,
}

#[cfg(any(target_os = "android", test))]
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct AndroidSessionState {
    pub version: u32,
    pub identity_id: Option<String>,
    pub pin_required: bool,
    pub secret: Vec<u8>,
    pub last_route: Option<String>,
}

#[cfg(any(target_os = "android", test))]
impl Default for AndroidSessionState {
    fn default() -> Self {
        Self {
            version: 1,
            identity_id: None,
            pin_required: true,
            secret: Vec::new(),
            last_route: None,
        }
    }
}

#[cfg(any(target_os = "android", test))]
impl Drop for AndroidSessionState {
    fn drop(&mut self) {
        self.secret.zeroize();
    }
}

#[cfg(any(target_os = "android", test))]
pub(crate) fn validate_session_route(path: &str) -> Result<(), String> {
    let page = path == "/chats"
        || path == "/contacts"
        || path == "/connect"
        || path == "/profile"
        || path.starts_with("/chats/")
        || path.starts_with("/connect/");
    if !page
        || path.len() > 512
        || path.contains("..")
        || path
            .bytes()
            .any(|c| !(c.is_ascii_alphanumeric() || b"/:%_-".contains(&c)))
    {
        return Err("Invalid saved app page".into());
    }
    let bytes = path.as_bytes();
    for index in 0..bytes.len() {
        if bytes[index] == b'%'
            && (index + 2 >= bytes.len()
                || !bytes[index + 1].is_ascii_hexdigit()
                || !bytes[index + 2].is_ascii_hexdigit())
        {
            return Err("Invalid saved app page".into());
        }
    }
    if let Some(component) = path
        .strip_prefix("/chats/")
        .or_else(|| path.strip_prefix("/connect/"))
    {
        let source = component.as_bytes();
        let mut decoded = Vec::new();
        let mut index = 0;
        while index < source.len() {
            if source[index] == b'%' {
                let byte = u8::from_str_radix(&component[index + 1..index + 3], 16)
                    .map_err(|_| "Invalid saved app page")?;
                decoded.push(byte);
                index += 3;
            } else {
                decoded.push(source[index]);
                index += 1;
            }
        }
        let identifier = std::str::from_utf8(&decoded).map_err(|_| "Invalid saved app page")?;
        if identifier.starts_with("did:cht:") {
            id_hash(identifier)?;
        } else if let Some(group_hash) = identifier.strip_prefix("group:") {
            if !path.starts_with("/chats/")
                || group_hash.len() != 64
                || !group_hash
                    .bytes()
                    .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))
            {
                return Err("Invalid saved app page".into());
            }
        } else if identifier.is_empty()
            || identifier.len() > 128
            || !identifier
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || b"_-".contains(&c))
        {
            return Err("Invalid saved app page".into());
        }
    }
    Ok(())
}

#[cfg(any(target_os = "android", test))]
impl DesktopVault {
    pub(crate) fn load_android_session(&self) -> Result<AndroidSessionState, String> {
        let path = self.root.join("android-session.bin");
        let file = match fs::File::open(path) {
            Ok(file) => file,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                return Ok(AndroidSessionState::default());
            }
            Err(error) => return Err(io_error(error)),
        };
        let mut encrypted = Vec::new();
        file.take(96 * 1024 + 1)
            .read_to_end(&mut encrypted)
            .map_err(io_error)?;
        if encrypted.len() > 96 * 1024 {
            return Err("Saved session is too large".into());
        }
        let plaintext =
            Zeroizing::new(self.protect(&encrypted, b"cht-android-session-v1", false)?);
        if plaintext.len() > 64 * 1024 {
            return Err("Saved session is too large".into());
        }
        let state: AndroidSessionState = serde_json::from_slice(&plaintext)
            .map_err(|_| "Saved session is invalid".to_owned())?;
        self.validate_android_session(&state)?;
        Ok(state)
    }

    fn validate_android_session(&self, state: &AndroidSessionState) -> Result<(), String> {
        if state.version != 1
            || state.secret.len() > 8192
            || (state.pin_required && !state.secret.is_empty())
            || (!state.pin_required && (state.identity_id.is_none() || state.secret.is_empty()))
        {
            return Err("Saved session is invalid".into());
        }
        if let Some(id) = &state.identity_id {
            self.read_entry(id)?;
        }
        if let Some(path) = &state.last_route {
            validate_session_route(path)?;
        }
        Ok(())
    }

    pub(crate) fn save_android_session(&self, state: &AndroidSessionState) -> Result<(), String> {
        self.validate_android_session(state)?;
        let plaintext = Zeroizing::new(
            serde_json::to_vec(state).map_err(|_| "Unable to save session".to_owned())?,
        );
        let protected = self.protect(&plaintext, b"cht-android-session-v1", true)?;
        atomic_write(&self.root.join("android-session.bin"), &protected)
    }
}

pub(crate) struct DesktopVault {
    root: PathBuf,
    #[cfg(target_os = "android")]
    wrapping_key: Option<Zeroizing<Vec<u8>>>,
    #[cfg(any(target_os = "linux", target_os = "macos"))]
    desktop_key: std::cell::OnceCell<Zeroizing<Vec<u8>>>,
}

impl DesktopVault {
    pub fn load_relay_state(&self) -> Result<String, String> {
        let path = self.root.join("relay-directory.json");
        if !path.exists() {
            return Ok(String::new());
        }
        let metadata = fs::metadata(&path).map_err(io_error)?;
        if metadata.len() > 8 * 1024 * 1024 {
            return Err("Relay cache is too large".into());
        }
        fs::read_to_string(path).map_err(io_error)
    }

    pub fn save_relay_state(&self, source: &str) -> Result<(), String> {
        if source.len() > 8 * 1024 * 1024 {
            return Err("Relay cache is too large".into());
        }
        serde_json::from_str::<serde_json::Value>(source).map_err(|_| "Invalid relay cache")?;
        atomic_write(&self.root.join("relay-directory.json"), source.as_bytes())
    }
    pub fn new(root: PathBuf) -> Self {
        Self {
            root,
            #[cfg(target_os = "android")]
            wrapping_key: None,
            #[cfg(any(target_os = "linux", target_os = "macos"))]
            desktop_key: std::cell::OnceCell::new(),
        }
    }

    #[cfg(target_os = "android")]
    pub fn for_android(root: PathBuf, key: Vec<u8>) -> Result<Self, String> {
        if !root.is_absolute() || key.len() != 32 {
            return Err("Invalid Android storage configuration".to_owned());
        }
        Ok(Self {
            root,
            wrapping_key: Some(Zeroizing::new(key)),
        })
    }

    fn protect(&self, bytes: &[u8], entropy: &[u8], encrypt: bool) -> Result<Vec<u8>, String> {
        #[cfg(target_os = "android")]
        {
            let device_key = self
                .wrapping_key
                .as_ref()
                .ok_or("Android secure storage has not been initialized")?;
            crate::android_storage::protect(device_key, bytes, entropy, encrypt)
        }
        #[cfg(any(target_os = "linux", target_os = "macos"))]
        return crate::android_storage::protect_with_domain(
            b"chta desktop storage v1",
            self.desktop_key(encrypt)?,
            bytes,
            entropy,
            encrypt,
        );
        #[cfg(not(any(target_os = "android", target_os = "linux", target_os = "macos")))]
        protect(bytes, entropy, encrypt)
    }

    #[cfg(any(target_os = "linux", target_os = "macos"))]
    fn desktop_key(&self, encrypt: bool) -> Result<&[u8], String> {
        if let Some(key) = self.desktop_key.get() {
            return Ok(key);
        }

        fs::create_dir_all(&self.root).map_err(io_error)?;
        let lock = fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(false)
            .open(self.root.join("keyring.lock"))
            .map_err(io_error)?;
        lock.lock().map_err(io_error)?;
        let unavailable = || {
            if cfg!(target_os = "macos") {
                "Unlock your login Keychain to use chta".to_owned()
            } else {
                "Unlock a Secret Service keyring in your desktop session to use chta".to_owned()
            }
        };
        let entry = keyring::Entry::new("app.cht.cht", "desktop-vault-key-v1")
            .map_err(|_| unavailable())?;
        let key = match entry.get_secret() {
            Ok(value) => Zeroizing::new(value),
            Err(keyring::Error::NoEntry) if encrypt && self.list()?.is_empty() => {
                let mut value = Zeroizing::new(vec![0u8; 32]);
                getrandom::fill(&mut value).map_err(|error| error.to_string())?;
                entry.set_secret(&value).map_err(|_| unavailable())?;
                value
            }
            Err(keyring::Error::NoEntry) => return Err("Desktop vault key is missing".into()),
            Err(_) => return Err(unavailable()),
        };
        if key.len() != 32 {
            return Err("Invalid desktop vault key".into());
        }
        Ok(self.desktop_key.get_or_init(|| key))
    }

    pub fn load_history(&self, id: &str) -> Result<String, String> {
        let path = self
            .root
            .join("history")
            .join(format!("{}.bin", id_hash(id)?));
        if !path.exists() {
            return Ok(String::new());
        }
        let bytes = fs::read(path).map_err(io_error)?;
        let plaintext = Zeroizing::new(self.protect(&bytes, id.as_bytes(), false)?);
        String::from_utf8(plaintext.to_vec()).map_err(|_| "Invalid saved chat history".to_owned())
    }

    pub fn save_history(&self, id: &str, source: &str) -> Result<(), String> {
        let path = self
            .root
            .join("history")
            .join(format!("{}.bin", id_hash(id)?));
        atomic_write(
            &path,
            &self.protect(source.as_bytes(), id.as_bytes(), true)?,
        )
    }

    fn attachment_path(&self, owner: &str, digest: &str) -> Result<PathBuf, String> {
        if digest.len() != 64
            || !digest
                .bytes()
                .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))
        {
            return Err("Invalid attachment digest".to_owned());
        }
        Ok(self
            .root
            .join("attachments")
            .join(id_hash(owner)?)
            .join(format!("{digest}.bin")))
    }

    pub fn save_attachment(&self, owner: &str, digest: &str, bytes: &[u8]) -> Result<(), String> {
        let path = self.attachment_path(owner, digest)?;
        if bytes.len() > MAX_ATTACHMENT_BYTES || format!("{:x}", Sha256::digest(bytes)) != digest {
            return Err("Invalid attachment size or digest".to_owned());
        }
        // Reuse a verified blob; a verified retransmission may repair corrupted storage.
        if let Ok(Some(existing)) = self.load_attachment(owner, digest) {
            let _existing = Zeroizing::new(existing);
            return Ok(());
        }
        let entropy = format!("cht-attachment-v1:{owner}:{digest}");
        atomic_write(&path, &self.protect(bytes, entropy.as_bytes(), true)?)
    }

    pub fn load_attachment(&self, owner: &str, digest: &str) -> Result<Option<Vec<u8>>, String> {
        let path = self.attachment_path(owner, digest)?;
        let max_encrypted = (MAX_ATTACHMENT_BYTES + 64 * 1024) as u64;
        let file = match fs::File::open(&path) {
            Ok(file) => file,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(io_error(error)),
        };
        if file.metadata().map_err(io_error)?.len() > max_encrypted {
            return Err("Attachment cache is too large".to_owned());
        }
        let mut encrypted = Vec::new();
        file.take(max_encrypted + 1)
            .read_to_end(&mut encrypted)
            .map_err(io_error)?;
        if encrypted.len() as u64 > max_encrypted {
            return Err("Attachment cache is too large".to_owned());
        }
        let entropy = format!("cht-attachment-v1:{owner}:{digest}");
        let plaintext = Zeroizing::new(self.protect(&encrypted, entropy.as_bytes(), false)?);
        if plaintext.len() > MAX_ATTACHMENT_BYTES
            || format!("{:x}", Sha256::digest(&*plaintext)) != digest
        {
            return Err("Attachment cache failed integrity check".to_owned());
        }
        Ok(Some(plaintext.to_vec()))
    }

    pub fn from_environment() -> Result<Self, String> {
        #[cfg(any(target_os = "linux", target_os = "macos"))]
        {
            let home = std::env::var_os("HOME").map(PathBuf::from);
            let base = if cfg!(target_os = "macos") {
                std::env::var_os("CHTA_MAC_DATA_HOME")
                    .map(PathBuf::from)
                    .or_else(|| home.map(|path| path.join("Library").join("Application Support")))
            } else {
                std::env::var_os("XDG_DATA_HOME")
                    .map(PathBuf::from)
                    .filter(|path| path.is_absolute())
                    .or_else(|| home.map(|path| path.join(".local").join("share")))
            };
            let base = base
                .filter(|path| path.is_absolute())
                .ok_or("Desktop application data directory is unavailable")?;
            Ok(Self::new(base.join("chta")))
        }
        #[cfg(not(any(target_os = "linux", target_os = "macos")))]
        {
            let base = std::env::var_os("APPDATA")
                .or_else(|| {
                    if cfg!(windows) {
                        None
                    } else {
                        Some(std::env::temp_dir().into_os_string())
                    }
                })
                .ok_or("Windows application data directory is unavailable")?;
            Ok(Self::new(PathBuf::from(base).join("cht")))
        }
    }

    fn identity_path(&self, id: &str) -> Result<PathBuf, String> {
        Ok(self
            .root
            .join("identities")
            .join(format!("{}.json", id_hash(id)?)))
    }

    fn state_path(&self, id: &str) -> Result<PathBuf, String> {
        Ok(self
            .root
            .join("accounts")
            .join(format!("{}.bin", id_hash(id)?)))
    }

    fn read_entry(&self, id: &str) -> Result<VaultEntry, String> {
        let entry: VaultEntry =
            serde_json::from_slice(&fs::read(self.identity_path(id)?).map_err(io_error)?)
                .map_err(|_| "Saved identity is unreadable".to_owned())?;
        if entry.version != VERSION || entry.identity.identity_id != id {
            return Err("Saved identity version or identifier is invalid".to_owned());
        }
        Ok(entry)
    }

    pub fn list(&self) -> Result<Vec<SavedIdentity>, String> {
        let directory = self.root.join("identities");
        if !directory.exists() {
            return Ok(Vec::new());
        }
        let mut entries = Vec::new();
        for file in fs::read_dir(directory).map_err(io_error)? {
            let path = file.map_err(io_error)?.path();
            if path.extension().and_then(|value| value.to_str()) != Some("json") {
                continue;
            }
            let entry: VaultEntry = serde_json::from_slice(&fs::read(path).map_err(io_error)?)
                .map_err(|_| "A saved identity is unreadable".to_owned())?;
            if entry.version != VERSION {
                return Err("Unsupported saved identity version".to_owned());
            }
            id_hash(&entry.identity.identity_id)?;
            entries.push(entry.identity);
        }
        entries.sort_by(|left, right| left.display_name.cmp(&right.display_name));
        Ok(entries)
    }

    pub fn remember(
        &self,
        id: &str,
        pin: &str,
        secret: &[u8],
        profile: &DesktopProfile,
    ) -> Result<(), String> {
        validate_pin(pin)?;
        let mut salt = [0u8; 16];
        getrandom::fill(&mut salt).map_err(|error| error.to_string())?;
        let entropy = pin_entropy(pin, &salt, id)?;
        let entry = VaultEntry {
            version: VERSION,
            identity: SavedIdentity {
                identity_id: id.to_owned(),
                display_name: profile.name.clone(),
                avatar: profile.contact_avatar.clone(),
                locked_until_milliseconds: 0,
            },
            salt: STANDARD.encode(salt),
            protected_secret: STANDARD.encode(self.protect(secret, &entropy, true)?),
            failed_attempts: 0,
        };
        atomic_write(
            &self.identity_path(id)?,
            &serde_json::to_vec(&entry).map_err(|error| error.to_string())?,
        )
    }

    pub fn unlock(&self, id: &str, pin: &str) -> Result<Zeroizing<Vec<u8>>, String> {
        validate_pin(pin)?;
        let mut entry = self.read_entry(id)?;
        if entry.identity.locked_until_milliseconds > now_milliseconds() {
            return Err(
                "Too many incorrect PINs. Please wait 30 seconds and try again.".to_owned(),
            );
        }
        let salt = STANDARD
            .decode(&entry.salt)
            .map_err(|_| "Invalid saved identity salt")?;
        if salt.len() != 16 {
            return Err("Invalid saved identity salt".to_owned());
        }
        let entropy = pin_entropy(pin, &salt, id)?;
        let encrypted = STANDARD
            .decode(&entry.protected_secret)
            .map_err(|_| "Invalid saved identity data")?;
        let decrypted = self.protect(&encrypted, &entropy, false);
        if decrypted.is_err() {
            entry.failed_attempts = entry.failed_attempts.saturating_add(1);
            if entry.failed_attempts >= 5 {
                entry.identity.locked_until_milliseconds = now_milliseconds() + 30_000;
                entry.failed_attempts = 0;
            }
        } else {
            entry.failed_attempts = 0;
            entry.identity.locked_until_milliseconds = 0;
        }
        atomic_write(
            &self.identity_path(id)?,
            &serde_json::to_vec(&entry).map_err(|error| error.to_string())?,
        )?;
        decrypted.map(Zeroizing::new).map_err(|_| {
            "Incorrect PIN or this identity cannot be unlocked on this device.".to_owned()
        })
    }

    pub fn load_data(&self, id: &str) -> Result<AccountData, String> {
        let path = self.state_path(id)?;
        if !path.exists() {
            let mut data = AccountData::default();
            // Adopt the old single profile only for the first saved identity.
            let legacy = self.root.join("profile.json");
            if self.list()?.is_empty() && legacy.exists() {
                data.profile = serde_json::from_slice(&fs::read(legacy).map_err(io_error)?)
                    .map_err(|_| "Unable to read the previous Desktop profile")?;
            }
            return Ok(data);
        }
        let bytes = fs::read(path).map_err(io_error)?;
        let plaintext = Zeroizing::new(self.protect(&bytes, id.as_bytes(), false)?);
        serde_json::from_slice(&plaintext)
            .map_err(|_| "Saved account data is unreadable".to_owned())
    }

    pub fn save_data(&self, id: &str, data: &AccountData) -> Result<(), String> {
        let source = Zeroizing::new(serde_json::to_vec(data).map_err(|error| error.to_string())?);
        atomic_write(
            &self.state_path(id)?,
            &self.protect(&source, id.as_bytes(), true)?,
        )?;
        if self.identity_path(id)?.exists() {
            let mut entry = self.read_entry(id)?;
            entry.identity.display_name = data.profile.name.clone();
            entry.identity.avatar = data.profile.contact_avatar.clone();
            atomic_write(
                &self.identity_path(id)?,
                &serde_json::to_vec(&entry).map_err(|error| error.to_string())?,
            )?;
        }
        Ok(())
    }
}

fn id_hash(id: &str) -> Result<&str, String> {
    let hash = id
        .strip_prefix("did:cht:")
        .ok_or("Invalid identity identifier")?;
    if hash.len() != 64 || !hash.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err("Invalid identity identifier".to_owned());
    }
    Ok(hash)
}

fn validate_pin(pin: &str) -> Result<(), String> {
    if !(6..=12).contains(&pin.len()) || !pin.bytes().all(|byte| byte.is_ascii_digit()) {
        return Err("PIN must contain 6 to 12 digits.".to_owned());
    }
    Ok(())
}

fn pin_entropy(pin: &str, salt: &[u8], id: &str) -> Result<Zeroizing<Vec<u8>>, String> {
    let params = Params::new(64 * 1024, 3, 1, Some(32)).map_err(|error| error.to_string())?;
    let mut key = Zeroizing::new(vec![0u8; 32 + id.len()]);
    Argon2::new(Algorithm::Argon2id, Version::V0x13, params)
        .hash_password_into(pin.as_bytes(), salt, &mut key[..32])
        .map_err(|error| error.to_string())?;
    key[32..].copy_from_slice(id.as_bytes());
    Ok(key)
}

fn atomic_write(path: &Path, bytes: &[u8]) -> Result<(), String> {
    fs::create_dir_all(path.parent().ok_or("Invalid account directory")?).map_err(io_error)?;
    let temporary = path.with_extension("tmp");
    let mut output = fs::File::create(&temporary).map_err(io_error)?;
    output.write_all(bytes).map_err(io_error)?;
    output.sync_all().map_err(io_error)?;
    drop(output);
    fs::rename(temporary, path).map_err(io_error)
}

fn now_milliseconds() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}

fn io_error(error: std::io::Error) -> String {
    format!("Unable to access saved Desktop identities: {error}")
}

#[cfg(windows)]
fn protect(bytes: &[u8], entropy: &[u8], encrypt: bool) -> Result<Vec<u8>, String> {
    use std::{ffi::c_void, ptr};
    #[repr(C)]
    struct Blob {
        length: u32,
        data: *mut u8,
    }
    #[link(name = "crypt32")]
    unsafe extern "system" {
        fn CryptProtectData(
            input: *const Blob,
            description: *const u16,
            entropy: *const Blob,
            reserved: *const c_void,
            prompt: *const c_void,
            flags: u32,
            output: *mut Blob,
        ) -> i32;
        fn CryptUnprotectData(
            input: *const Blob,
            description: *mut *mut u16,
            entropy: *const Blob,
            reserved: *const c_void,
            prompt: *const c_void,
            flags: u32,
            output: *mut Blob,
        ) -> i32;
    }
    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn LocalFree(memory: *mut c_void) -> *mut c_void;
    }
    let input = Blob {
        length: bytes
            .len()
            .try_into()
            .map_err(|_| "Account data is too large")?,
        data: bytes.as_ptr().cast_mut(),
    };
    let entropy = Blob {
        length: entropy
            .len()
            .try_into()
            .map_err(|_| "Invalid protection context")?,
        data: entropy.as_ptr().cast_mut(),
    };
    let mut output = Blob {
        length: 0,
        data: ptr::null_mut(),
    };
    // SAFETY: Input buffers remain valid for the synchronous DPAPI call; output is freed with LocalFree.
    let result = unsafe {
        if encrypt {
            CryptProtectData(
                &input,
                ptr::null(),
                &entropy,
                ptr::null(),
                ptr::null(),
                1,
                &mut output,
            )
        } else {
            CryptUnprotectData(
                &input,
                ptr::null_mut(),
                &entropy,
                ptr::null(),
                ptr::null(),
                1,
                &mut output,
            )
        }
    };
    if result == 0 {
        return Err("Windows could not unlock the protected data".to_owned());
    }
    // SAFETY: A successful DPAPI call returns output.length initialized bytes.
    let copy = unsafe { std::slice::from_raw_parts(output.data, output.length as usize).to_vec() };
    // SAFETY: The output is owned by this call; clear plaintext before releasing the allocation.
    unsafe {
        ptr::write_bytes(output.data, 0, output.length as usize);
        LocalFree(output.data.cast());
    }
    Ok(copy)
}

#[cfg(not(any(
    windows,
    target_os = "android",
    target_os = "linux",
    target_os = "macos"
)))]
fn protect(_: &[u8], _: &[u8], _: bool) -> Result<Vec<u8>, String> {
    Err("PIN identity storage is currently available on Windows Desktop only".to_owned())
}

#[cfg(all(test, windows))]
mod attachment_tests {
    use super::*;
    use sha2::{Digest, Sha256};

    struct Folder(PathBuf);
    impl Folder {
        fn new() -> Self {
            Self(std::env::temp_dir().join(format!(
                    "cht-attachment-test-{}-{}",
                    std::process::id(),
                    SystemTime::now()
                        .duration_since(UNIX_EPOCH)
                        .unwrap()
                        .as_nanos()
                )))
        }
        fn vault(&self) -> DesktopVault {
            DesktopVault::new(self.0.clone())
        }
        fn path(&self, owner: &str, digest: &str) -> PathBuf {
            self.0
                .join("attachments")
                .join(&owner[8..])
                .join(format!("{digest}.bin"))
        }
    }
    impl Drop for Folder {
        fn drop(&mut self) {
            if self.0.exists() {
                assert_eq!(
                    self.0.parent().unwrap().canonicalize().unwrap(),
                    std::env::temp_dir().canonicalize().unwrap()
                );
                assert!(
                    self.0
                        .file_name()
                        .unwrap()
                        .to_str()
                        .unwrap()
                        .starts_with("cht-attachment-test-")
                );
                fs::remove_dir_all(&self.0).unwrap();
            }
        }
    }
    fn owner(c: char) -> String {
        format!("did:cht:{}", c.to_string().repeat(64))
    }
    fn digest(data: &[u8]) -> String {
        format!("{:x}", Sha256::digest(data))
    }

    #[test]
    fn attachment_cache_is_encrypted_reopenable_and_idempotent() {
        let folder = Folder::new();
        let owner = owner('a');
        let data = b"private cached fixture without a download click";
        let hash = digest(data);
        folder.vault().save_attachment(&owner, &hash, data).unwrap();
        let encrypted = fs::read(folder.path(&owner, &hash)).unwrap();
        assert!(!encrypted.windows(data.len()).any(|part| part == data));
        assert_eq!(
            folder
                .vault()
                .load_attachment(&owner, &hash)
                .unwrap()
                .as_deref(),
            Some(data.as_slice())
        );
        folder.vault().save_attachment(&owner, &hash, data).unwrap();
        assert_eq!(fs::read(folder.path(&owner, &hash)).unwrap(), encrypted);
    }

    #[test]
    fn attachment_cache_binds_ciphertext_to_owner_and_digest() {
        let folder = Folder::new();
        let alice = owner('a');
        let bob = owner('b');
        let data = b"owner-bound file";
        let hash = digest(data);
        let vault = folder.vault();
        vault.save_attachment(&alice, &hash, data).unwrap();
        assert_eq!(vault.load_attachment(&bob, &hash).unwrap(), None);
        let bob_path = folder.path(&bob, &hash);
        fs::create_dir_all(bob_path.parent().unwrap()).unwrap();
        fs::copy(folder.path(&alice, &hash), &bob_path).unwrap();
        assert!(vault.load_attachment(&bob, &hash).is_err());
        let other_hash = digest(b"different bytes");
        fs::copy(folder.path(&alice, &hash), folder.path(&alice, &other_hash)).unwrap();
        assert!(vault.load_attachment(&alice, &other_hash).is_err());
    }

    #[test]
    fn attachment_cache_rejects_invalid_paths_hashes_sizes_and_corruption() {
        let folder = Folder::new();
        let owner = owner('a');
        let vault = folder.vault();
        assert!(vault.save_attachment(&owner, "../outside", b"x").is_err());
        assert!(vault.load_attachment("not-a-did", &digest(b"x")).is_err());
        assert!(
            vault
                .save_attachment(&owner, &digest(b"other"), b"x")
                .is_err()
        );
        assert!(
            vault
                .save_attachment(&owner, &digest(b""), &vec![0; 100 * 1024 * 1024 + 1])
                .is_err()
        );
        let hash = digest(b"fixture");
        vault.save_attachment(&owner, &hash, b"fixture").unwrap();
        let path = folder.path(&owner, &hash);
        let mut corrupted = fs::read(&path).unwrap();
        corrupted[0] ^= 0x80;
        fs::write(&path, &corrupted).unwrap();
        assert!(vault.load_attachment(&owner, &hash).is_err());
        assert_eq!(fs::read(&path).unwrap(), corrupted);
        fs::OpenOptions::new()
            .write(true)
            .open(&path)
            .unwrap()
            .set_len(101 * 1024 * 1024)
            .unwrap();
        assert!(vault.load_attachment(&owner, &hash).is_err());
    }
}

mod chunked;
mod group_blobs;

#[cfg(test)]
mod session_route_tests {
    use super::validate_session_route;
    #[test]
    fn group_room_route_is_accepted_without_weakening_session_validation() {
        let gid = format!("group:{}", "a".repeat(64));
        for path in [
            format!("/chats/{gid}"),
            format!("/chats/group%3A{}", "a".repeat(64)),
        ] {
            assert!(validate_session_route(&path).is_ok(), "{path}");
        }
        for path in [
            format!("/connect/{gid}"),
            "/chats/group:short".into(),
            format!("/chats/group:{}", "A".repeat(64)),
            format!("/chats/{gid}/extra"),
        ] {
            assert!(validate_session_route(&path).is_err(), "{path}");
        }
    }
}
