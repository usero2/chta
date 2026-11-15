import 'dart:ffi';

import 'package:ffi/ffi.dart';

final class _BasicLimits extends Struct {
  @Int64()
  external int processTime;
  @Int64()
  external int jobTime;
  @Uint32()
  external int flags;
  @UintPtr()
  external int minWorkingSet;
  @UintPtr()
  external int maxWorkingSet;
  @Uint32()
  external int activeProcesses;
  @UintPtr()
  external int affinity;
  @Uint32()
  external int priority;
  @Uint32()
  external int scheduling;
}

final class _Counters extends Struct {
  @Uint64()
  external int readOperations;
  @Uint64()
  external int writeOperations;
  @Uint64()
  external int otherOperations;
  @Uint64()
  external int readBytes;
  @Uint64()
  external int writeBytes;
  @Uint64()
  external int otherBytes;
}

final class _ExtendedLimits extends Struct {
  external _BasicLimits basic;
  external _Counters counters;
  @UintPtr()
  external int processMemory;
  @UintPtr()
  external int jobMemory;
  @UintPtr()
  external int peakProcessMemory;
  @UintPtr()
  external int peakJobMemory;
}

/// Windows closes the job handle when cht exits, including an abrupt exit.
/// KILL_ON_JOB_CLOSE prevents a public tunnel surviving its owning app.
class WindowsProcessJob {
  WindowsProcessJob() {
    _job = _create(nullptr, nullptr);
    if (_job == nullptr) {
      throw StateError('Could not create the relay process group.');
    }
    final limits = calloc<_ExtendedLimits>();
    try {
      limits.ref.basic.flags = 0x2000;
      if (_set(_job, 9, limits.cast(), sizeOf<_ExtendedLimits>()) == 0) {
        close();
        throw StateError('Could not protect the relay process lifetime.');
      }
    } finally {
      calloc.free(limits);
    }
  }
  static final _library = DynamicLibrary.open('kernel32.dll');
  static final _create = _library
      .lookupFunction<
        Pointer<Void> Function(Pointer<Void>, Pointer<Utf16>),
        Pointer<Void> Function(Pointer<Void>, Pointer<Utf16>)
      >('CreateJobObjectW');
  static final _set = _library
      .lookupFunction<
        Int32 Function(Pointer<Void>, Int32, Pointer<Void>, Uint32),
        int Function(Pointer<Void>, int, Pointer<Void>, int)
      >('SetInformationJobObject');
  static final _open = _library
      .lookupFunction<
        Pointer<Void> Function(Uint32, Int32, Uint32),
        Pointer<Void> Function(int, int, int)
      >('OpenProcess');
  static final _assign = _library
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Void>),
        int Function(Pointer<Void>, Pointer<Void>)
      >('AssignProcessToJobObject');
  static final _close = _library
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('CloseHandle');
  Pointer<Void> _job = nullptr;
  void add(int pid) {
    final process = _open(0x0100 | 0x0001, 0, pid); // SET_QUOTA | TERMINATE
    if (process == nullptr) {
      throw StateError('Could not manage the relay process.');
    }
    try {
      if (_assign(_job, process) == 0) {
        throw StateError('Could not attach the relay process to its owner.');
      }
    } finally {
      _close(process);
    }
  }

  void close() {
    if (_job != nullptr) {
      _close(_job);
      _job = nullptr;
    }
  }
}
