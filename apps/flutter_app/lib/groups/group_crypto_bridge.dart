abstract interface class GroupCryptoBridge {
  Future<Map<String, Object?>> groupCall(
    String operation,
    Map<String, Object?> args,
  );
}
