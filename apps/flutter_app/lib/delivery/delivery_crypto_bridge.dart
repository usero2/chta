/// Versioned delivery/Courier cryptography; private keys and job keys stay in Rust.
abstract interface class DeliveryCryptoBridge {
  Future<Map<String, Object?>> deliveryCall(
    String operation,
    Map<String, Object?> args,
  );
}
