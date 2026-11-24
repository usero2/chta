import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

typedef _SpaceNative = Int32 Function(
  Pointer<Utf16>,
  Pointer<Uint64>,
  Pointer<Uint64>,
  Pointer<Uint64>,
);
typedef _SpaceDart = int Function(
  Pointer<Utf16>,
  Pointer<Uint64>,
  Pointer<Uint64>,
  Pointer<Uint64>,
);

Future<int?> availableCacheSpace() async {
  try {
    if (Platform.isAndroid) {
      return await const MethodChannel('app.cht/platform')
          .invokeMethod<int>('availableStorage');
    }
    final directory = await getApplicationSupportDirectory();
    if (Platform.isWindows) {
      final getSpace = DynamicLibrary.open('kernel32.dll')
          .lookupFunction<_SpaceNative, _SpaceDart>('GetDiskFreeSpaceExW');
      final path = directory.path.toNativeUtf16(), free = calloc<Uint64>();
      try {
        return getSpace(path, free, nullptr, nullptr) == 0 ? null : free.value;
      } finally {
        calloc.free(path);
        calloc.free(free);
      }
    }
    final result = await Process.run('df', ['-Pk', directory.path]);
    if (result.exitCode != 0) return null;
    final lines = (result.stdout as String).trim().split('\n');
    final fields = lines.last.trim().split(RegExp(r'\s+'));
    final available = fields.length < 4 ? null : int.tryParse(fields[3]);
    return available == null ? null : available * 1024;
  } catch (_) {
    return null;
  }
}
