import 'dart:js_interop';

import 'attachment_store.dart';

@JS('chtCore.loadPeerAttachment')
external JSPromise<JSString?> _load(JSString owner, JSString digest);
@JS('chtCore.savePeerAttachment')
external JSPromise<JSAny?> _save(
  JSString owner,
  JSString digest,
  JSString data,
);
AttachmentStore createPlatformAttachmentStore() =>
    BridgeAttachmentStore(_WebAttachmentBridge());

class _WebAttachmentBridge implements AttachmentBridge {
  @override
  Future<String?> loadPeerAttachment(String ownerId, String digest) async {
    return (await _load(ownerId.toJS, digest.toJS).toDart)?.toDart;
  }

  @override
  Future<void> savePeerAttachment(
    String ownerId,
    String digest,
    String data,
  ) async {
    await _save(ownerId.toJS, digest.toJS, data.toJS).toDart;
  }
}
