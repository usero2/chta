use chacha20poly1305::{
    KeyInit, XChaCha20Poly1305, XNonce,
    aead::{Aead, Payload},
};
use zeroize::Zeroizing;

#[cfg(any(target_os = "android", test))]
pub(crate) fn protect(
    device_key: &[u8],
    bytes: &[u8],
    context: &[u8],
    encrypt: bool,
) -> Result<Vec<u8>, String> {
    protect_with_domain(
        b"cht android storage v1",
        device_key,
        bytes,
        context,
        encrypt,
    )
}

pub(crate) fn protect_with_domain(
    domain: &[u8],
    device_key: &[u8],
    bytes: &[u8],
    context: &[u8],
    encrypt: bool,
) -> Result<Vec<u8>, String> {
    if device_key.len() != 32 {
        return Err("Invalid storage key".to_owned());
    }
    let mut key = Zeroizing::new([0u8; 32]);
    hkdf::Hkdf::<sha2::Sha256>::new(Some(domain), device_key)
        .expand(context, &mut *key)
        .map_err(|_| "Invalid storage protection context")?;
    let cipher = XChaCha20Poly1305::new_from_slice(&*key).map_err(|_| "Invalid storage key")?;
    if encrypt {
        let mut nonce = [0u8; 24];
        getrandom::fill(&mut nonce).map_err(|error| error.to_string())?;
        let ciphertext = cipher
            .encrypt(
                XNonce::from_slice(&nonce),
                Payload {
                    msg: bytes,
                    aad: context,
                },
            )
            .map_err(|_| "Unable to encrypt stored data")?;
        let mut output = vec![1];
        output.extend_from_slice(&nonce);
        output.extend_from_slice(&ciphertext);
        Ok(output)
    } else {
        if bytes.len() < 41 || bytes[0] != 1 {
            return Err("Invalid encrypted data".to_owned());
        }
        cipher
            .decrypt(
                XNonce::from_slice(&bytes[1..25]),
                Payload {
                    msg: &bytes[25..],
                    aad: context,
                },
            )
            .map_err(|_| "Unable to unlock protected data".to_owned())
    }
}

#[cfg(test)]
mod tests {
    use super::protect;

    #[test]
    fn storage_roundtrip_requires_original_device_and_context() {
        let fixture = b"isolated identity fixture";
        let key = [7; 32];
        let encrypted = protect(&key, fixture, b"identity-A-PIN-context", true).unwrap();
        assert_eq!(
            protect(&key, &encrypted, b"identity-A-PIN-context", false).unwrap(),
            fixture
        );
        assert!(!encrypted.windows(fixture.len()).any(|part| part == fixture));
        assert!(protect(&[8; 32], &encrypted, b"identity-A-PIN-context", false).is_err());
        assert!(protect(&key, &encrypted, b"identity-B-PIN-context", false).is_err());
        assert_ne!(
            encrypted,
            protect(&key, fixture, b"identity-A-PIN-context", true).unwrap()
        );
    }

    #[test]
    fn storage_rejects_tampering_truncation_and_unknown_version() {
        let key = [3; 32];
        let encrypted = protect(&key, b"history fixture", b"history-A", true).unwrap();
        for index in 0..encrypted.len() {
            let mut corrupted = encrypted.clone();
            corrupted[index] ^= 1;
            assert!(protect(&key, &corrupted, b"history-A", false).is_err());
        }
        for length in 0..encrypted.len() {
            assert!(protect(&key, &encrypted[..length], b"history-A", false).is_err());
        }
        assert!(protect(&[1; 16], b"fixture", b"context", true).is_err());
    }
}
