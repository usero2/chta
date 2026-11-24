import 'dart:convert';
import 'dart:typed_data';

const courierPackageBytes = 256 * 1024;
const courierMaxPackages = 40960;
const courierMaxHistoricalNodes = 64;
bool courierHex(String value, int size) =>
    RegExp('^[0-9a-f]{$size}\$').hasMatch(value);

class IndexBitmap {
  IndexBitmap(this.count) : _bits = _checkedBits(count);
  static Uint8List _checkedBits(int count) {
    if (count < 2 || count > courierMaxPackages) {
      throw const FormatException('Invalid package count');
    }
    return Uint8List((count + 7) ~/ 8);
  }

  IndexBitmap._(this.count, this._bits, this._length);
  final int count;
  final Uint8List _bits;
  int _length = 0;
  int get length => _length;
  bool contains(int index) =>
      index >= 0 &&
      index < count &&
      (_bits[index >> 3] & (1 << (index & 7))) != 0;
  bool mark(int index) {
    if (index < 0 || index >= count) throw RangeError.index(index, _bits);
    if (contains(index)) return false;
    _bits[index >> 3] |= 1 << (index & 7);
    _length++;
    return true;
  }

  IndexBitmap copy() =>
      IndexBitmap._(count, Uint8List.fromList(_bits), _length);
  String get encoded => base64UrlEncode(_bits).replaceAll('=', '');
  int intersectionLength(IndexBitmap other) {
    if (other.count != count) {
      throw const FormatException('Bitmap count mismatch');
    }
    var total = 0;
    for (var i = 0; i < _bits.length; i++) {
      var bits = _bits[i] & other._bits[i];
      while (bits != 0) {
        bits &= bits - 1;
        total++;
      }
    }
    return total;
  }

  void merge(IndexBitmap other) {
    if (other.count != count) {
      throw const FormatException('Bitmap count mismatch');
    }
    for (var i = 0; i < _bits.length; i++) {
      var added = other._bits[i] & ~_bits[i];
      _bits[i] |= other._bits[i];
      while (added != 0) {
        added &= added - 1;
        _length++;
      }
    }
  }

  factory IndexBitmap.fromEncoded(int count, String encoded) {
    final result = IndexBitmap(count);
    if (encoded.length > ((count + 7) ~/ 8 + 2) ~/ 3 * 4) {
      throw const FormatException('Package bitmap too large');
    }
    final bytes = base64Url.decode(base64Url.normalize(encoded));
    if (bytes.length != result._bits.length ||
        base64UrlEncode(bytes).replaceAll('=', '') != encoded) {
      throw const FormatException('Invalid package bitmap');
    }
    for (var i = 0; i < bytes.length * 8; i++) {
      if ((bytes[i >> 3] & (1 << (i & 7))) != 0) {
        if (i >= count) throw const FormatException('Invalid bitmap padding');
        result.mark(i);
      }
    }
    return result;
  }
}

/// Constructed only after Rust verifies the certificate and advertisement.
class CourierNode {
  CourierNode.verified({
    required this.nodeId,
    required this.ownerId,
    required Map<String, Object?> certificate,
    required List<String> routes,
    required this.expiresAt,
    required this.freeBytes,
    this.maxPackageBytes = courierPackageBytes,
  }) : certificate = Map.unmodifiable(certificate),
       routes = List.unmodifiable(routes) {
    if (!courierHex(nodeId, 64) ||
        routes.isEmpty ||
        routes.length > 8 ||
        freeBytes < 0 ||
        freeBytes > 1024 * 1024 * 1024 * 1024) {
      throw const FormatException('Invalid Courier node');
    }
  }
  final String nodeId, ownerId;
  final Map<String, Object?> certificate;
  final List<String> routes;
  final int expiresAt, freeBytes, maxPackageBytes;
  bool eligible(int now) =>
      expiresAt > now && maxPackageBytes >= courierPackageBytes;
}

enum CourierJobStatus {
  preparing,
  waitingForNodes,
  depositing,
  stored,
  paused,
  cancelled,
  expired,
  delivered,
  failed,
}
