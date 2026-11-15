import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'p2p_bridge.dart';
import 'p2p_bridge_android.dart';

typedef _CallNative = Pointer<Utf8> Function(Pointer<Utf8> request);
typedef _CallDart = Pointer<Utf8> Function(Pointer<Utf8> request);
typedef _FreeNative = Void Function(Pointer<Utf8> value);
typedef _FreeDart = void Function(Pointer<Utf8> value);

P2pBridge createPlatformP2pBridge() =>
    Platform.isAndroid ? androidP2pBridge : _NativeP2pBridge();

class _NativeP2pBridge implements P2pBridge {
  _CallDart? _call;
  _FreeDart? _free;
  String _profileName = '';

  void _ensureLibrary() {
    if (_call != null) return;
    final directory = File(Platform.resolvedExecutable).parent.path;
    final libraryName = Platform.isWindows
        ? 'cht_mesh.dll'
        : Platform.isMacOS
        ? 'libcht_mesh.dylib'
        : 'libcht_mesh.so';
    final library = DynamicLibrary.open(
      '$directory${Platform.pathSeparator}$libraryName',
    );
    _call = library.lookupFunction<_CallNative, _CallDart>('cht_mesh_call');
    _free = library.lookupFunction<_FreeNative, _FreeDart>(
      'cht_mesh_free_string',
    );
  }

  Object? _invoke(String command, [Map<String, Object?> args = const {}]) {
    _ensureLibrary();
    final request = jsonEncode({'command': command, 'args': args})
        .toNativeUtf8();
    Pointer<Utf8> response = nullptr;
    try {
      response = _call!(request);
      final document = jsonDecode(response.toDartString());
      if (document is! Map<String, Object?>) {
        throw const FormatException('Native mesh returned an invalid response');
      }
      if (document['ok'] != true) {
        throw StateError('${document['error'] ?? 'Native mesh failed'}');
      }
      return document['value'];
    } finally {
      malloc.free(request);
      if (response != nullptr) _free!(response);
    }
  }

  ListenerStatus _listenerStatus(Object? value) =>
      ListenerStatus.fromJson((value! as Map).cast<String, Object?>());

  @override
  bool get supportsListening => true;

  @override
  bool get supportsAutomaticContact => false;

  @override
  Future<ListenerStatus> startListening(
    int port,
    String pin,
    bool allowRelay,
    String contactCard,
  ) async => _listenerStatus(
    _invoke('startListener', {
      'port': port,
      'pin': pin,
      'allowRelay': allowRelay,
      'contactCard': contactCard,
    }),
  );

  @override
  Future<ListenerStatus> stopListening() async =>
      _listenerStatus(_invoke('stopListener'));

  @override
  Future<ListenerStatus> listenerStatus() async =>
      _listenerStatus(_invoke('listenerStatus'));

  @override
  Future<void> updateListenerContactCard(String contactCard) async {
    _invoke('updateListenerContactCard', {'contactCard': contactCard});
  }

  Future<T> _pending<T>() => Future.error(
    UnsupportedError('Use an internet relay or a browser connection for chat.'),
  );

  @override
  Future<void> acceptAnswer(String signal) => _pending();
  @override
  Future<String> acceptOffer(
    String signal,
    String stunUrl,
    String displayName,
  ) => _pending();
  @override
  Future<void> close() async {}
  @override
  Future<String> createOffer(String stunUrl, String displayName) => _pending();
  @override
  Future<String> createRoom(String offer) => _pending();
  @override
  Future<List<PeerEvent>> drainEvents() async {
    final values = _invoke('drainGatewayEvents')! as List<Object?>;
    return values
        .map((value) {
          final event = (value! as Map).cast<String, Object?>();
          return PeerEvent(
            type: event['eventType']! as String,
            text: event['text'] as String?,
          );
        })
        .toList(growable: false);
  }

  @override
  Future<String?> loadRoomAnswer(String code) => _pending();
  @override
  Future<String> loadRoomOffer(String code) => _pending();
  @override
  Future<void> publishRoomAnswer(String code, String answer) => _pending();
  @override
  Future<String> profileName() async => _profileName;
  @override
  Future<void> setProfileName(String name) async => _profileName = name.trim();
  @override
  Future<void> sendMessage(
    String messageId,
    String text, {
    int? sentAtMilliseconds,
  }) => _pending();
  @override
  Future<void> acknowledgeMessage(
    String messageId,
    int receivedAtMilliseconds,
  ) => sendTransportFrame(
    jsonEncode({
      'type': 'ack',
      'messageId': messageId,
      'receivedAtMilliseconds': receivedAtMilliseconds,
    }),
  );
  @override
  Future<void> sendTransportFrame(String frame) async {
    _invoke('sendGatewayMessage', {'text': frame});
  }

  @override
  Future<void> connectContact(String identityId, String displayName) =>
      _pending();
  @override
  Future<Map<String, Object?>> status() async => const {
    'connectionState': 'new',
    'authenticated': false,
  };
}
