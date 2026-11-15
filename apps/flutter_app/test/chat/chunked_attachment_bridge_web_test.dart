@TestOn('browser')
library;

import 'dart:js_interop';

import 'package:cht/chat/chunked_attachment_bridge.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

@JS('eval')
external JSAny? _eval(JSString source);

class _BrowserHost implements BrowserChunkedStorageHost {}

void main() {
  test('Web finish rejects a digest different from incrementally read chunks', () async {
    _eval('''
      globalThis.chtCore = {
        chunkedAttachmentStatus: async () => JSON.stringify({
          version: 2, id: 'attachment_12345678', size: 3, chunkSize: 3,
          contiguousChunks: 1, completed: false, digest: null,
        }),
        readChunkedAttachment: async () => new Uint8Array([1, 2, 3]),
        finishChunkedAttachment: async () => { throw Error('Unexpected seal'); },
      };
    '''.toJS);
    final bridge = createChunkedAttachmentBridge(bridge: _BrowserHost())!;
    await expectLater(
      bridge.finishChunkedAttachment(
        'disposable-owner',
        'attachment_12345678',
        expectedDigest: sha256.convert([1, 2, 4]).toString(),
      ),
      throwsStateError,
    );
  });
}
