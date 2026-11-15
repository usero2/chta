/// Fragment already encrypted Noise frames; plaintext never enters this layer.
const _partSize = 12000, _maxCiphertext = 65536;
final _hexId = RegExp(r'^[0-9a-f]{32}$');
final _ciphertext = RegExp(r'^[A-Za-z0-9_-]+$');

List<Map<String, dynamic>> fragmentGroupCiphertext(
  String session,
  String id,
  String source,
) {
  if (!_hexId.hasMatch(session) ||
      !_hexId.hasMatch(id) ||
      source.isEmpty ||
      source.length > _maxCiphertext ||
      !_ciphertext.hasMatch(source)) {
    throw const FormatException('Invalid group ciphertext');
  }
  final count = (source.length + _partSize - 1) ~/ _partSize;
  return List.generate(
    count,
    (index) => {
      'v': 1,
      't': 'box',
      's': session,
      'id': id,
      'i': index,
      'n': count,
      'data': source.substring(
        index * _partSize,
        ((index + 1) * _partSize).clamp(0, source.length),
      ),
    },
  );
}

class GroupFrameAssembler {
  final _pending = <String, _Assembly>{};
  final _completed = <String>{};
  void clear() {
    _pending.clear();
    _completed.clear();
  }

  String? add(Map<String, dynamic> part, String session, int now) {
    _pending.removeWhere((_, assembly) => now - assembly.started >= 15000);
    final id = part['id'],
        index = part['i'],
        count = part['n'],
        data = part['data'];
    if (part.length != 7 ||
        part['v'] != 1 ||
        part['t'] != 'box' ||
        part['s'] != session ||
        id is! String ||
        !_hexId.hasMatch(id) ||
        index is! int ||
        count is! int ||
        count < 1 ||
        count > 6 ||
        index < 0 ||
        index >= count ||
        data is! String ||
        !_ciphertext.hasMatch(data) ||
        data.length > _partSize ||
        (index < count - 1 && data.length != _partSize) ||
        (index == count - 1 &&
            (count - 1) * _partSize + data.length > _maxCiphertext)) {
      throw const FormatException('Invalid encrypted group fragment');
    }
    if (_completed.contains(id)) return null;
    var assembly = _pending[id];
    if (assembly == null) {
      if (_pending.length >= 4) {
        throw StateError('Too many pending group frames');
      }
      assembly = _Assembly(now, count);
      _pending[id] = assembly;
    }
    if (assembly.parts.length != count ||
        assembly.parts[index] != null && assembly.parts[index] != data) {
      _pending.remove(id);
      throw const FormatException('Conflicting group fragment');
    }
    assembly.parts[index] = data;
    if (assembly.parts.any((p) => p == null)) return null;
    _pending.remove(id);
    _completed.add(id);
    if (_completed.length > 256) _completed.remove(_completed.first);
    return assembly.parts.join();
  }
}

class _Assembly {
  _Assembly(this.started, int count)
    : parts = List<String?>.filled(count, null);
  final int started;
  final List<String?> parts;
}
