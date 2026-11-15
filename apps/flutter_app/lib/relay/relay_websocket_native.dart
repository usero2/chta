import 'dart:convert';
import 'dart:io';

final _dnsCache = <String, (DateTime, List<InternetAddress>)>{};

bool _publicAddress(InternetAddress address) {
  if (address.isLoopback || address.isLinkLocal || address.isMulticast) {
    return false;
  }
  final bytes = address.rawAddress;
  if (address.type == InternetAddressType.IPv4) {
    return bytes[0] != 0 &&
        bytes[0] != 10 &&
        bytes[0] != 127 &&
        bytes[0] < 224 &&
        !(bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) &&
        !(bytes[0] == 192 && bytes[1] == 168) &&
        !(bytes[0] == 100 && bytes[1] >= 64 && bytes[1] <= 127);
  }
  return bytes.any((byte) => byte != 0) &&
      (bytes[0] & 0xfe) != 0xfc &&
      !(bytes.take(10).every((byte) => byte == 0) &&
          bytes[10] == 255 &&
          bytes[11] == 255);
}

Future<List<InternetAddress>> _quickTunnelAddresses(String host) async {
  final cached = _dnsCache[host];
  if (cached != null && cached.$1.isAfter(DateTime.now())) return cached.$2;
  // Quick Tunnel names can initially return NXDOMAIN. Query DoH before the
  // first OS lookup so a negative Windows DNS cache does not hide a new tunnel.
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  try {
    final request = await client
        .getUrl(
          Uri.https('cloudflare-dns.com', '/dns-query', {
            'name': host,
            'type': 'A',
          }),
        )
        .timeout(const Duration(seconds: 6));
    request.headers.set('Accept', 'application/dns-json');
    final response = await request.close().timeout(const Duration(seconds: 6));
    if (response.statusCode != 200) {
      throw const SocketException('Relay DNS is unavailable');
    }
    final bytes = <int>[];
    await for (final chunk in response.timeout(const Duration(seconds: 6))) {
      bytes.addAll(chunk);
      if (bytes.length > 65536) {
        throw const FormatException('DNS response is too large');
      }
    }
    final value = jsonDecode(utf8.decode(bytes)) as Map;
    final addresses = <InternetAddress>[];
    if (value['Status'] == 0) {
      for (final answer in (value['Answer'] as List? ?? []).take(16)) {
        if ((answer as Map)['type'] == 1) {
          final address = InternetAddress.tryParse(answer['data'] as String);
          if (address != null && _publicAddress(address)) {
            addresses.add(address);
          }
        }
      }
    }
    if (addresses.isEmpty) {
      throw const SocketException(
        'The public relay DNS record is not ready yet',
      );
    }
    _dnsCache.removeWhere((_, entry) => entry.$1.isBefore(DateTime.now()));
    if (_dnsCache.length >= 64) _dnsCache.remove(_dnsCache.keys.first);
    _dnsCache[host] = (
      DateTime.now().add(const Duration(seconds: 30)),
      addresses,
    );
    return addresses;
  } finally {
    client.close(force: true);
  }
}

Future<WebSocket> connectRelayWebSocket(String endpoint) async {
  final uri = Uri.parse(endpoint);
  final local =
      uri.host == 'localhost' ||
      InternetAddress.tryParse(uri.host)?.isLoopback == true;
  if (local) {
    return WebSocket.connect(endpoint).timeout(const Duration(seconds: 8));
  }
  final addresses = uri.host.endsWith('.trycloudflare.com')
      ? await _quickTunnelAddresses(uri.host)
      : await InternetAddress.lookup(uri.host)
            .timeout(const Duration(seconds: 6));
  if (addresses.isEmpty ||
      addresses.any((address) => !_publicAddress(address))) {
    throw const SocketException(
      'Shared relay DNS must resolve to public addresses',
    );
  }
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  // Keep the original URL/SNI and normal certificate validation, while dialing
  // the exact vetted public IP. Never disable TLS verification.
  client.connectionFactory = (url, proxyHost, proxyPort) async {
    if (url.host != uri.host || proxyHost != null) {
      throw const SocketException('Unexpected relay connection target');
    }
    final port = uri.hasPort ? uri.port : (uri.scheme == 'wss' ? 443 : 80);
    final task = await Socket.startConnect(addresses.first, port);
    Socket? transport;
    final secured = task.socket.then<Socket>((raw) async {
      transport = raw;
      try {
        final tls = await SecureSocket.secure(raw, host: uri.host);
        transport = tls;
        return tls;
      } catch (_) {
        raw.destroy();
        rethrow;
      }
    });
    // A custom HttpClient factory supplies the complete socket, including TLS.
    return ConnectionTask.fromSocket(secured, () {
      task.cancel();
      transport?.destroy();
    });
  };
  var connected = false;
  try {
    // Dart's WebSocket implementation copies Uri.port while converting wss to
    // https. Supply the default explicitly so it never emits a Host port of 0.
    final dialUri = uri.hasPort
        ? uri
        : uri.replace(port: uri.scheme == 'wss' ? 443 : 80);
    final socket = await WebSocket.connect(
      dialUri.toString(),
      customClient: client,
    ).timeout(const Duration(seconds: 8));
    connected = true;
    return socket;
  } finally {
    client.close(force: !connected);
  }
}
