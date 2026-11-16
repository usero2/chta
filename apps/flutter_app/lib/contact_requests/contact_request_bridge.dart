/// Seals and verifies contact setup in Rust; private keys never enter Dart.
abstract interface class ContactRequestBridge {
  Future<Map<String, Object?>> contactRequestCall(
    String operation,
    Map<String, Object?> args,
  );
}
