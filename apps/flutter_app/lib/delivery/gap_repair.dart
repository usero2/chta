import 'dart:convert';

import 'package:crypto/crypto.dart';

const gapRepairPrefix = 'chta-gap-v1:';
const gapRepairControlId = 'cht-control-gap-v1';

class GapRecord {
  GapRecord(this.id, this.source);
  final String id, source;
  late final String digest = sha256.convert(utf8.encode(source)).toString();
}

typedef GapRecords = List<GapRecord> Function(String scope);
typedef GapCheckpoint = Future<void> Function(
  String scope,
  String snapshot,
  int next,
);
typedef GapResume = Future<int> Function(String scope, String snapshot);

class _Inventory {
  _Inventory(this.rows);
  final List<GapRecord> rows;
  late final String snapshot = sha256
      .convert(
        utf8.encode(
          jsonEncode([
            for (final row in rows) [row.id, row.digest],
          ]),
        ),
      )
      .toString();
}

class _Pull {
  _Pull(this.scope, this.snapshot, this.total, this.offset, this.until);
  final String scope, snapshot;
  final int total;
  int offset, until;
  int? pageEnd;
  final missing = <(String, String)>[];
  final parts = <String>[];
}

/// One bounded history pull per authenticated peer. Both ends check the scope
/// before serving a page or applying a record. A checkpoint follows storage.
class GapRepair {
  GapRepair({
    required this.send,
    required this.authorize,
    required this.records,
    required this.contains,
    required this.commit,
    required this.checkpoint,
    required this.resume,
    int Function()? clock,
  }) : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  static const pageSize = 16, maxRecords = 512, maxRecordBytes = 65536;
  static const _partSize = 8192;
  static final _hash = RegExp(r'^[0-9a-f]{64}$');
  final Future<void> Function(String frame) send;
  final Future<bool> Function(String scope) authorize;
  final GapRecords records;
  final bool Function(String scope, String id) contains;
  final Future<void> Function(String scope, GapRecord record) commit;
  final GapCheckpoint checkpoint;
  final GapResume resume;
  final int Function() _clock;
  _Inventory? _inventory;
  String? _offered;
  _Pull? _pull;
  int _offerUntil = 0, _replyBudget = 0;
  bool _closed = false, _receiving = false;

  Future<void> offer(String scope) async {
    if (_closed || (_offerUntil > _clock() && _offered != scope)) return;
    if (!await authorize(scope) || _closed) return;
    final ids = <String>{};
    final rows = <GapRecord>[];
    var bytes = 0;
    for (final row in records(scope).take(maxRecords)) {
      if (row.id.isEmpty || row.id.length > 340 || !ids.add(row.id)) continue;
      final length = utf8.encode(row.source).length;
      if (length == 0 || length > maxRecordBytes) continue;
      if (bytes + length > 512 * 1024) break;
      bytes += length;
      rows.add(row);
    }
    final inventory = _Inventory(rows);
    if (inventory.rows.isEmpty) return;
    _inventory = inventory;
    _offered = scope;
    _offerUntil = _clock() + 15000;
    _replyBudget = 96;
    await _emit(scope, inventory.snapshot, 'offer', {
      'total': inventory.rows.length,
    });
  }

  Future<void> _emit(
    String scope,
    String snapshot,
    String op,
    Map<String, Object?> body,
  ) async {
    if (_closed) return;
    await send(
      '$gapRepairPrefix${jsonEncode({'s': scope, 'h': snapshot, 'op': op, ...body})}',
    );
  }

  Future<void> receive(String frame) async {
    if (_closed ||
        _receiving ||
        !frame.startsWith(gapRepairPrefix) ||
        utf8.encode(frame).length > 12000) {
      return;
    }
    _receiving = true;
    try {
      final body = Map<String, Object?>.from(
        jsonDecode(frame.substring(gapRepairPrefix.length)) as Map,
      );
      final scope = body['s'], snapshot = body['h'];
      if (scope is! String ||
          scope.length > 256 ||
          snapshot is! String ||
          !_hash.hasMatch(snapshot)) {
        return;
      }
      if (!await authorize(scope) || _closed) return;
      switch (body['op']) {
        case 'offer':
          final total = body['total'];
          if (total is! int || total < 1 || total > maxRecords) return;
          if (_pull case final existing? when existing.until > _clock()) return;
          final offset = await resume(scope, snapshot);
          if (_closed || offset < 0 || offset >= total) return;
          _pull = _Pull(scope, snapshot, total, offset, _clock() + 15000);
          await _advance(_pull!);
        case 'page?':
          final inventory = _serving(scope, snapshot), offset = body['at'];
          if (inventory == null ||
              offset is! int ||
              offset < 0 ||
              offset >= inventory.rows.length ||
              offset % pageSize != 0) {
            return;
          }
          final rows = inventory.rows.skip(offset).take(pageSize);
          await _emit(scope, snapshot, 'page', {
            'at': offset,
            'rows': [
              for (final row in rows) [row.id, row.digest],
            ],
          });
        case 'record?':
          final inventory = _serving(scope, snapshot),
              id = body['id'],
              digest = body['d'];
          final row = inventory?.rows
              .where((r) => r.id == id && r.digest == digest)
              .firstOrNull;
          if (row == null) return;
          final data = base64UrlEncode(utf8.encode(row.source));
          for (var start = 0; start < data.length; start += _partSize) {
            if (_closed || !await authorize(scope)) return;
            final end = (start + _partSize).clamp(0, data.length);
            await _emit(scope, snapshot, 'data', {
              'id': row.id,
              'p': start ~/ _partSize,
              'last': end == data.length,
              'b': data.substring(start, end),
            });
          }
        case 'page':
          final pull = _receivingFor(scope, snapshot), rows = body['rows'];
          if (pull == null ||
              pull.pageEnd != null ||
              body['at'] != pull.offset ||
              rows is! List ||
              rows.length != (pull.total - pull.offset).clamp(1, pageSize)) {
            return;
          }
          final seen = <String>{};
          for (final row in rows) {
            if (row is! List ||
                row.length != 2 ||
                row[0] is! String ||
                row[1] is! String) {
              throw const FormatException('Invalid repair page');
            }
            final id = row[0] as String, digest = row[1] as String;
            if (id.isEmpty ||
                id.length > 340 ||
                !_hash.hasMatch(digest) ||
                !seen.add(id)) {
              throw const FormatException('Invalid repair identity');
            }
            if (!contains(scope, id)) pull.missing.add((id, digest));
          }
          pull.pageEnd = pull.offset + rows.length;
          await _advance(pull);
        case 'data':
          final pull = _receivingFor(scope, snapshot), data = body['b'];
          if (pull == null ||
              pull.missing.isEmpty ||
              body['id'] != pull.missing.first.$1 ||
              body['p'] != pull.parts.length ||
              data is! String ||
              data.isEmpty ||
              data.length > _partSize ||
              pull.parts.length >= 11 ||
              body['last'] is! bool) {
            return;
          }
          pull.parts.add(data);
          if (body['last'] != true) return;
          final bytes = base64Url.decode(pull.parts.join());
          if (bytes.length > maxRecordBytes) {
            throw const FormatException('Repair record too large');
          }
          final row = GapRecord(pull.missing.first.$1, utf8.decode(bytes));
          if (row.digest != pull.missing.first.$2) {
            throw const FormatException('Repair digest mismatch');
          }
          if (!contains(scope, row.id)) await commit(scope, row);
          if (_closed || !identical(_pull, pull)) return;
          pull.parts.clear();
          pull.missing.removeAt(0);
          await _advance(pull);
      }
    } catch (_) {
      _pull = null;
    } finally {
      _receiving = false;
    }
  }

  _Inventory? _serving(String scope, String snapshot) {
    final inventory = _inventory;
    if (inventory == null ||
        _offered != scope ||
        inventory.snapshot != snapshot ||
        _offerUntil <= _clock() ||
        _replyBudget-- <= 0) {
      return null;
    }
    _offerUntil = _clock() + 15000;
    return inventory;
  }

  _Pull? _receivingFor(String scope, String snapshot) {
    final pull = _pull;
    if (pull == null ||
        pull.scope != scope ||
        pull.snapshot != snapshot ||
        pull.until <= _clock()) {
      return null;
    }
    pull.until = _clock() + 15000;
    return pull;
  }

  Future<void> _advance(_Pull pull) async {
    if (_closed || !identical(_pull, pull)) return;
    if (pull.missing.isNotEmpty) {
      final (id, digest) = pull.missing.first;
      await _emit(pull.scope, pull.snapshot, 'record?', {
        'id': id,
        'd': digest,
      });
      return;
    }
    if (pull.pageEnd case final next?) {
      await checkpoint(pull.scope, pull.snapshot, next);
      if (_closed) return;
      pull.offset = next;
      pull.pageEnd = null;
    }
    if (pull.offset == pull.total) {
      _pull = null;
      return;
    }
    await _emit(pull.scope, pull.snapshot, 'page?', {'at': pull.offset});
  }

  void close() {
    _closed = true;
    _pull = null;
    _inventory = null;
  }
}
