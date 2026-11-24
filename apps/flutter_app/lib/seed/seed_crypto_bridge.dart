/// Signs discovery signals and binds received signals to the unlocked owner
/// and an existing verified contact. Secret signing keys remain in Rust.
abstract interface class SeedCryptoBridge {
  Future<String> signSeedSignal(
    String peerId,
    String messageId,
    String text,
    int now,
  );

  Future<String> inspectSeedSignal(String source, String expectedPeer, int now);
}

/// Optional capability for updated seed servers. Keys remain in the Rust core.
abstract interface class SeedDispatchCryptoBridge {
  Future<String> signSeedDispatch(
    String seedId,
    String connection,
    int sequence,
    String envelopeJson,
  );
}
