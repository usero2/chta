import 'dart:js_interop';

import 'peer_history_store.dart';

@JS('chtCore.loadPeerHistory')
external JSPromise<JSString> _load(JSString owner);
@JS('chtCore.savePeerHistory')
external JSPromise<JSAny?> _save(JSString owner, JSString source);

PeerHistoryStore createPlatformPeerHistoryStore() => _WebStore();

class _WebStore implements PeerHistoryStore {
  @override
  Future<String?> load(String ownerId) async {
    final source = (await _load(ownerId.toJS).toDart).toDart;
    return source.isEmpty ? null : source;
  }

  @override
  Future<void> save(String ownerId, String source) async {
    await _save(ownerId.toJS, source.toJS).toDart;
  }
}
