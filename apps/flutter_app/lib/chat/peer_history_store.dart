import 'peer_history_store_stub.dart'
    if (dart.library.io) 'peer_history_store_native.dart'
    if (dart.library.js_interop) 'peer_history_store_web.dart';
import '../account/desktop_identity_bridge.dart';
import '../groups/group_blob_bridge.dart';
import 'room_history_store.dart';

abstract interface class PeerHistoryStore {
  Future<String?> load(String ownerId);
  Future<void> save(String ownerId, String source);
}

abstract interface class IncrementalPeerHistoryStore
    implements PeerHistoryStore {
  Future<void> saveChanges(
    String ownerId,
    String metadata,
    Map<String, String?> rooms,
  );
}

PeerHistoryStore createPeerHistoryStore({
  DesktopIdentityBridge? identityBridge,
  GroupBlobBridge? roomBlobs,
}) {
  final legacy = identityBridge?.usesPlatformHistory == true
      ? _PlatformHistoryStore(identityBridge!)
      : createPlatformPeerHistoryStore();
  return roomBlobs == null
      ? legacy
      : RoomHistoryStore(legacy: legacy, blobs: roomBlobs);
}

class _PlatformHistoryStore implements PeerHistoryStore {
  _PlatformHistoryStore(this.bridge);
  final DesktopIdentityBridge bridge;
  @override
  Future<String?> load(String ownerId) => bridge.loadNativeHistory(ownerId);
  @override
  Future<void> save(String ownerId, String source) =>
      bridge.saveNativeHistory(ownerId, source);
}
