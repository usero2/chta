import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

http.Client createLinkPreviewClient() {
  final client = HttpClient()
    ..findProxy = ((_) => 'DIRECT')
    ..connectionTimeout = const Duration(seconds: 2);
  client.connectionFactory = (url, _, _) async {
    final addresses = await InternetAddress.lookup(url.host);
    final address = addresses.where(_publicAddress).firstOrNull;
    if (address == null) {
      throw const SocketException('Preview requires a public host.');
    }
    // Connect to the address we checked, while HttpClient validates TLS for the URL.
    return Socket.startConnect(address, url.port);
  };
  return IOClient(client);
}

bool _publicAddress(InternetAddress address) {
  final ip = address.rawAddress;
  if (ip.length == 16) {
    return ip[0] & 0xe0 == 0x20 &&
        !(ip[0] == 0x20 && ip[1] == 1 && ip[2] == 0x0d && ip[3] == 0xb8);
  }
  final a = ip[0], b = ip[1], c = ip[2];
  return !(a == 0 ||
      a == 10 ||
      a == 127 ||
      a >= 224 ||
      a == 100 && b >= 64 && b <= 127 ||
      a == 169 && b == 254 ||
      a == 172 && b >= 16 && b <= 31 ||
      a == 192 && (b == 0 || b == 168) ||
      a == 198 && (b == 18 || b == 19 || b == 51 && c == 100) ||
      a == 203 && b == 0 && c == 113);
}
