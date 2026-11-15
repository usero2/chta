import 'peer_history_store.dart';

PeerHistoryStore createPlatformPeerHistoryStore() => _MemoryStore();

class _MemoryStore implements PeerHistoryStore {
  final _values = <String, String>{};
  @override
  Future<String?> load(String ownerId) async => _values[ownerId];
  @override
  Future<void> save(String ownerId, String source) async {
    _values[ownerId] = source;
  }
}
