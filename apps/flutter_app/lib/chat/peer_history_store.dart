import 'peer_history_store_stub.dart'
    if (dart.library.io) 'peer_history_store_native.dart'
    if (dart.library.js_interop) 'peer_history_store_web.dart';
import '../account/desktop_identity_bridge.dart';

abstract interface class PeerHistoryStore {
  Future<String?> load(String ownerId);
  Future<void> save(String ownerId, String source);
}

PeerHistoryStore createPeerHistoryStore({
  DesktopIdentityBridge? identityBridge,
}) => identityBridge?.usesPlatformHistory == true
    ? _PlatformHistoryStore(identityBridge!)
    : createPlatformPeerHistoryStore();

class _PlatformHistoryStore implements PeerHistoryStore {
  _PlatformHistoryStore(this.bridge);
  final DesktopIdentityBridge bridge;
  @override
  Future<String?> load(String ownerId) => bridge.loadNativeHistory(ownerId);
  @override
  Future<void> save(String ownerId, String source) =>
      bridge.saveNativeHistory(ownerId, source);
}
