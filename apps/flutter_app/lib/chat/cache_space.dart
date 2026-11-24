import 'cache_space_stub.dart'
    if (dart.library.io) 'cache_space_native.dart'
    if (dart.library.js_interop) 'cache_space_web.dart'
    as platform;

Future<int?> availableCacheSpace() => platform.availableCacheSpace();
