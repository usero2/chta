/// Operations stay in Rust so private identity keys never enter Dart/JavaScript.
abstract interface class RelayCryptoBridge {
  Future<String> relayProof(String nonce, String relayId);
  Future<String> inspectRelayRecord(String source, int now, bool allowLoopback);
  Future<String> loadRelayState();
  Future<void> saveRelayState(String source);
}
