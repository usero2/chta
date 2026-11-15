use std::{
    fs::{self, OpenOptions},
    io::{Read, Write},
    path::Path,
};

use argon2::{Algorithm, Argon2, Params, Version};
use base64::{Engine as _, engine::general_purpose::STANDARD};
use chacha20poly1305::{
    KeyInit, XChaCha20Poly1305, XNonce,
    aead::{Aead, Payload},
};
use libp2p::identity::Keypair;
use serde::{Deserialize, Serialize};
use zeroize::Zeroizing;

use crate::RelayResult;

const CONTEXT: &[u8] = b"cht relay identity v1";

#[cfg(not(windows))]
pub fn windows_password(_: &Path) -> RelayResult<Zeroizing<Vec<u8>>> {
    Err("--windows-credential is only available on Windows".into())
}

#[cfg(windows)]
pub fn windows_password(state: &Path) -> RelayResult<Zeroizing<Vec<u8>>> {
    std::fs::create_dir_all(state)?;
    let path = state.join("credential.dpapi");
    if path.try_exists()? {
        return Ok(Zeroizing::new(windows_protect(
            &read_bounded(&path, 16384)?,
            false,
        )?));
    }
    if state.join("identity.enc.json").try_exists()? {
        return Err("Relay identity exists but its Windows credential is missing; restore the original credential".into());
    }
    let mut secret = Zeroizing::new(vec![0u8; 48]);
    getrandom::fill(&mut secret)?;
    let protected = windows_protect(&secret, true)?;
    let mut file = OpenOptions::new().write(true).create_new(true).open(path)?;
    file.write_all(&protected)?;
    file.sync_all()?;
    Ok(secret)
}

#[cfg(windows)]
fn windows_protect(bytes: &[u8], encrypt: bool) -> RelayResult<Vec<u8>> {
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
        length: bytes.len().try_into()?,
        data: bytes.as_ptr().cast_mut(),
    };
    let context = b"cht relay Windows credential v1";
    let entropy = Blob {
        length: context.len() as u32,
        data: context.as_ptr().cast_mut(),
    };
    let mut output = Blob {
        length: 0,
        data: ptr::null_mut(),
    };
    // SAFETY: Buffers live across this synchronous DPAPI call. UI is disabled.
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
        return Err("Windows could not unlock this relay credential".into());
    }
    // SAFETY: Successful DPAPI output is initialized and owned by this call.
    let copy = unsafe { std::slice::from_raw_parts(output.data, output.length as usize).to_vec() };
    // SAFETY: Clear plaintext before releasing the DPAPI allocation.
    unsafe {
        ptr::write_bytes(output.data, 0, output.length as usize);
        LocalFree(output.data.cast());
    }
    Ok(copy)
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct EncryptedIdentity {
    version: u32,
    salt: String,
    nonce: String,
    ciphertext: String,
}

fn read_bounded(path: &Path, limit: u64) -> RelayResult<Zeroizing<Vec<u8>>> {
    let metadata = fs::symlink_metadata(path)?;
    if !metadata.is_file() || metadata.file_type().is_symlink() {
        return Err("Identity and credential paths must be regular files".into());
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        if metadata.permissions().mode() & 0o077 != 0 {
            return Err("Identity and credential files must be private (chmod 600 or 400)".into());
        }
    }
    let mut bytes = Zeroizing::new(Vec::new());
    fs::File::open(path)?
        .take(limit + 1)
        .read_to_end(&mut bytes)?;
    if bytes.len() as u64 > limit {
        return Err("Identity or credential file is too large".into());
    }
    Ok(bytes)
}

pub fn password_from_file(path: &Path) -> RelayResult<Zeroizing<Vec<u8>>> {
    let bytes = read_bounded(path, 4096)?;
    let password = bytes.trim_ascii();
    if password.len() < 32 {
        return Err(
            "The identity password must contain at least 32 bytes; use a generated random secret"
                .into(),
        );
    }
    Ok(Zeroizing::new(password.to_vec()))
}

fn cipher(password: &[u8], salt: &[u8]) -> RelayResult<XChaCha20Poly1305> {
    let mut key = Zeroizing::new([0u8; 32]);
    let argon = Argon2::new(
        Algorithm::Argon2id,
        Version::V0x13,
        Params::new(65536, 3, 1, Some(32)).map_err(|_| "Invalid identity protection parameters")?,
    );
    argon
        .hash_password_into(password, salt, &mut *key)
        .map_err(|_| "Unable to derive identity protection key")?;
    Ok(XChaCha20Poly1305::new_from_slice(&*key).map_err(|_| "Invalid identity protection key")?)
}

pub fn load_or_create(state_dir: &Path, password: &[u8]) -> RelayResult<Keypair> {
    if password.len() < 32 {
        return Err("Identity password is too short".into());
    }
    let mut builder = fs::DirBuilder::new();
    builder.recursive(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        builder.mode(0o700);
    }
    builder.create(state_dir)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        if fs::symlink_metadata(state_dir)?.file_type().is_symlink()
            || fs::metadata(state_dir)?.permissions().mode() & 0o077 != 0
        {
            return Err(
                "Relay state directory must be private (chmod 700) and not a symlink".into(),
            );
        }
    }
    let path = state_dir.join("identity.enc.json");
    if path.try_exists()? {
        let source = read_bounded(&path, 16384)?;
        let stored: EncryptedIdentity = serde_json::from_slice(&source)
            .map_err(|_| "Encrypted relay identity is invalid; it will not be replaced")?;
        let salt = STANDARD
            .decode(&stored.salt)
            .map_err(|_| "Invalid identity salt")?;
        let nonce = STANDARD
            .decode(&stored.nonce)
            .map_err(|_| "Invalid identity nonce")?;
        if stored.version != 1 || salt.len() != 16 || nonce.len() != 24 {
            return Err("Unsupported or invalid encrypted relay identity".into());
        }
        let ciphertext = STANDARD
            .decode(&stored.ciphertext)
            .map_err(|_| "Invalid encrypted relay identity")?;
        let plaintext = Zeroizing::new(cipher(password, &salt)?.decrypt(
            XNonce::from_slice(&nonce), Payload { msg: &ciphertext, aad: CONTEXT },
        ).map_err(|_| "Unable to unlock relay identity; verify the credential and backup (identity was not replaced)")?);
        return Keypair::from_protobuf_encoding(&plaintext)
            .map_err(|_| "Relay identity key is invalid".into());
    }
    let keypair = Keypair::generate_ed25519();
    let secret = Zeroizing::new(keypair.to_protobuf_encoding()?);
    let mut salt = [0u8; 16];
    let mut nonce = [0u8; 24];
    getrandom::fill(&mut salt)?;
    getrandom::fill(&mut nonce)?;
    let encrypted = cipher(password, &salt)?
        .encrypt(
            XNonce::from_slice(&nonce),
            Payload {
                msg: &secret,
                aad: CONTEXT,
            },
        )
        .map_err(|_| "Unable to encrypt relay identity")?;
    let entry = EncryptedIdentity {
        version: 1,
        salt: STANDARD.encode(salt),
        nonce: STANDARD.encode(nonce),
        ciphertext: STANDARD.encode(encrypted),
    };
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options.open(path)?;
    file.write_all(&serde_json::to_vec_pretty(&entry)?)?;
    file.sync_all()?;
    Ok(keypair)
}
