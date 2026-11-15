import 'core_bridge.dart';
import 'core_bridge_stub.dart'
    if (dart.library.io) 'core_bridge_native.dart'
    if (dart.library.js_interop) 'core_bridge_web.dart';

AppBridge createCoreBridge() => createPlatformCoreBridge();
