import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'peer_history_store.dart';

final class _Blob extends Struct {
  @Uint32()
  external int length;
  external Pointer<Uint8> data;
}

typedef _ProtectNative = Int32 Function(
  Pointer<_Blob>,
  Pointer<Utf16>,
  Pointer<_Blob>,
  Pointer<Void>,
  Pointer<Void>,
  Uint32,
  Pointer<_Blob>,
);
typedef _ProtectDart = int Function(
  Pointer<_Blob>,
  Pointer<Utf16>,
  Pointer<_Blob>,
  Pointer<Void>,
  Pointer<Void>,
  int,
  Pointer<_Blob>,
);
typedef _LocalFreeNative = Pointer<Void> Function(Pointer<Void>);
typedef _LocalFreeDart = Pointer<Void> Function(Pointer<Void>);

PeerHistoryStore createPlatformPeerHistoryStore() => NativePeerHistoryStore();

class NativePeerHistoryStore implements PeerHistoryStore {
  NativePeerHistoryStore({this.directory});
  final Directory? directory;

  File _file(String ownerId) {
    final base = Platform.environment['APPDATA'] ?? Directory.current.path;
    final owner = base64Url.encode(utf8.encode(ownerId)).replaceAll('=', '');
    final folder =
        directory?.path ??
        '$base${Platform.pathSeparator}cht${Platform.pathSeparator}history';
    return File('$folder${Platform.pathSeparator}$owner.bin');
  }

  Uint8List _crypt(Uint8List bytes, {required bool protect}) {
    if (!Platform.isWindows) {
      throw UnsupportedError('Encrypted history storage requires Windows');
    }
    final crypt = DynamicLibrary.open('crypt32.dll')
        .lookupFunction<_ProtectNative, _ProtectDart>(
          protect ? 'CryptProtectData' : 'CryptUnprotectData',
        );
    final free = DynamicLibrary.open('kernel32.dll')
        .lookupFunction<_LocalFreeNative, _LocalFreeDart>('LocalFree');
    final input = calloc<_Blob>();
    final output = calloc<_Blob>();
    final data = calloc<Uint8>(bytes.length);
    try {
      data.asTypedList(bytes.length).setAll(0, bytes);
      input.ref.length = bytes.length;
      input.ref.data = data;
      // CRYPTPROTECT_UI_FORBIDDEN: protection is tied to this Windows user.
      if (crypt(input, nullptr, nullptr, nullptr, nullptr, 1, output) == 0) {
        throw StateError('Windows could not protect chat history');
      }
      return Uint8List.fromList(output.ref.data.asTypedList(output.ref.length));
    } finally {
      data.asTypedList(bytes.length).fillRange(0, bytes.length, 0);
      if (output.ref.data != nullptr) free(output.ref.data.cast());
      calloc.free(data);
      calloc.free(input);
      calloc.free(output);
    }
  }

  @override
  Future<String?> load(String ownerId) async {
    final file = _file(ownerId);
    if (!await file.exists()) return null;
    return utf8.decode(_crypt(await file.readAsBytes(), protect: false));
  }

  @override
  Future<void> save(String ownerId, String source) async {
    final file = _file(ownerId);
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsBytes(
      _crypt(Uint8List.fromList(utf8.encode(source)), protect: true),
      flush: true,
    );
    await temporary.rename(file.path);
  }
}
