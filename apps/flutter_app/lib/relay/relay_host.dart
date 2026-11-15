import 'package:flutter/foundation.dart';

import 'relay_host_stub.dart'
    if (dart.library.io) 'relay_host_native.dart'
    as platform;

abstract class RelayHost extends ChangeNotifier {
  bool get enabled;
  bool get working;
  bool get running;
  String? get endpoint;
  String? get error;
  Future<void> start(List<String> bootstrapUrls);
  Future<void> stop();
  Future<void> shutdown();
}

RelayHost? createRelayHost() => platform.createHost();
