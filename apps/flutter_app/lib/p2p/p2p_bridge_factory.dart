import 'p2p_bridge.dart';
import 'p2p_bridge_stub.dart'
    if (dart.library.io) 'p2p_bridge_native.dart'
    if (dart.library.js_interop) 'p2p_bridge_web.dart';

P2pBridge createP2pBridge() => createPlatformP2pBridge();
