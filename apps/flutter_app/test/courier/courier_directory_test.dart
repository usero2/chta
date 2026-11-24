import 'package:cht/courier/courier_directory.dart';
import 'package:cht/delivery/delivery_crypto_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

class Crypto implements DeliveryCryptoBridge {
  @override
  Future<Map<String, Object?>> deliveryCall(
    String op,
    Map<String, Object?> args,
  ) async {
    final c = Map<String, Object?>.from(args['control'] as Map);
    if (c['signature'] != 'valid' || c['signerId'] != args['expectedSigner']) {
      throw StateError('forged');
    }
    return c;
  }
}

Map<String, Object?> ad(
  String node, {
  String? owner,
  int issued = 1000,
  List<String>? routes,
}) {
  owner ??= 'did:cht:${'b' * 64}';
  return {
    'version': 1,
    'kind': 'advertisement',
    'signerId': node,
    'publicKey': 'key',
    'certificate': {'nodeId': node, 'ownerId': owner},
    'challenge': 'A' * 43,
    'issuedAt': issued,
    'expiresAt': issued + 900000,
    'signature': 'valid',
    'body': {
      'version': 1,
      'nodeId': node,
      'ownerId': owner,
      'routes': routes ?? ['wss://relay.example.com/cht'],
      'maxPackageBytes': 262144,
      'freeBytes': 1073741824,
    },
  };
}

void main() {
  test('rotating gossip pages remain below seed frame limits', () async {
    final directory = CourierDirectory(crypto: Crypto(), clock: () => 2000);
    final domain = '${'a' * 60}.${'b' * 60}.${'c' * 60}.example.com';
    await directory.merge([
      for (var i = 1; i <= 8; i++)
        ad(
          i.toRadixString(16).padLeft(64, '0'),
          routes: [for (var j = 0; j < 8; j++) 'wss://$j.$domain/cht'],
        ),
    ]);
    final batch = directory.batch();
    expect(batch.length, lessThan(8));
    directory.close();
  });
  test('signed advertisements deduplicate URLs by certified identity and expire without trusting discovery', () async {
    var time = 2000;
    final directory = CourierDirectory(crypto: Crypto(), clock: () => time);
    await directory.merge([
      ad(
        'a' * 64,
        routes: ['wss://one.example.com/cht', 'wss://two.example.com/cht'],
      ),
    ]);
    expect(directory.nodes, hasLength(1));
    expect(directory.nodes.single.routes, hasLength(2));
    final forged = ad('c' * 64)..['signature'] = 'forged';
    await directory.merge([
      forged,
      ad('a' * 64, issued: 1000, routes: ['wss://other.example.com/cht']),
    ]);
    expect(directory.nodes, hasLength(1));
    expect(directory.nodes.single.routes.first, 'wss://one.example.com/cht');
    final invalid = ad('d' * 64);
    (invalid['body'] as Map)['routes'] = ['wss://127.0.0.1/cht'];
    await directory.merge([invalid]);
    expect(directory.nodes, hasLength(1));
    time = 901001;
    directory.prune();
    expect(directory.nodes, isEmpty);
    directory.close();
  });
  test('per-owner and global discovery work stay bounded and stale async verification cannot revive a closed directory', () async {
    final directory = CourierDirectory(crypto: Crypto(), clock: () => 2000);
    await directory.merge([
      for (var i = 1; i <= 8; i++) ad(i.toRadixString(16).padLeft(64, '0')),
    ]);
    await directory.merge([ad('f' * 64)]);
    expect(directory.nodes, hasLength(8));
    directory.close();
    await directory.merge([ad('e' * 64)]);
    expect(directory.nodes, isEmpty);
  });
}
