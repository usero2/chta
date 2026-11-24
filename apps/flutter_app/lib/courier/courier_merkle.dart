import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'courier_models.dart';

/// One bounded tree per active job; proofs are generated in logarithmic time.
class CourierMerkleTree {
  CourierMerkleTree._(this._levels);
  final List<List<String>> _levels;
  String get root => _levels.last.single;
  static List<int> _raw(String hash) => [
    for (var i = 0; i < 64; i += 2)
      int.parse(hash.substring(i, i + 2), radix: 16),
  ];
  static Future<CourierMerkleTree> build(List<String> hashes) async {
    if (hashes.length < 2 ||
        hashes.length > courierMaxPackages ||
        hashes.any((h) => !courierHex(h, 64))) {
      throw const FormatException('Invalid Courier Merkle leaves');
    }
    final levels = <List<String>>[List.unmodifiable(hashes)],
        prefix = utf8.encode('chta courier branch v1\u0000');
    var work = 0;
    while (levels.last.length > 1) {
      final source = levels.last, next = <String>[];
      for (var i = 0; i < source.length; i += 2) {
        final left = source[i],
            right = source[(i + 1).clamp(0, source.length - 1)];
        next.add(
          sha256.convert([...prefix, ..._raw(left), ..._raw(right)]).toString(),
        );
        if (++work % 512 == 0) await Future<void>.delayed(Duration.zero);
      }
      levels.add(List.unmodifiable(next));
    }
    return CourierMerkleTree._(List.unmodifiable(levels));
  }

  List<String> proof(int index) {
    if (index < 0 || index >= _levels.first.length) {
      throw RangeError.index(index, _levels.first);
    }
    final result = <String>[];
    for (final level in _levels.take(_levels.length - 1)) {
      result.add(
        level[index.isOdd ? index - 1 : (index + 1).clamp(0, level.length - 1)],
      );
      index >>= 1;
    }
    return List.unmodifiable(result);
  }
}
