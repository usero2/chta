abstract interface class RoutedContactBridge {
  Future<String> contactCardWithRelays({
    String displayName = '',
    String avatar = '',
    List<String> relayUrls = const [],
  });
}
