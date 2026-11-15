abstract interface class GroupBlobBridge {
  Future<String?> loadGroupBlob(String ownerId, String key);
  Future<void> saveGroupBlob(String ownerId, String key, String value);
  Future<void> deleteGroupBlob(String ownerId, String key);
}
