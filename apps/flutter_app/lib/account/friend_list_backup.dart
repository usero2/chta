import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;

import 'package:file_picker/file_picker.dart';

import 'account_bridge.dart';
import 'account_models.dart';

class FriendListBackup {
  FriendListBackup._(this._friends, this._invalid);

  static const _format = 'chta-friends';
  static const _version = 1;
  static const _maxBytes = 32 * 1024 * 1024;

  final List<({String card, String alias})> _friends;
  final int _invalid;

  int get count => _friends.length + _invalid;

  factory FriendListBackup.decode(Uint8List bytes) {
    _checkSize(bytes.length);
    final data = jsonDecode(utf8.decode(bytes));
    if (data is! Map ||
        data['format'] != _format ||
        data['version'] != _version) {
      throw const FormatException('Choose a chta friend list backup.');
    }
    final entries = data['friends'];
    if (entries is! List) {
      throw const FormatException('The friend list is missing.');
    }
    final friends = <({String card, String alias})>[];
    var invalid = 0;
    for (final entry in entries) {
      if (entry is! Map || entry['card'] is! Map) {
        invalid++;
        continue;
      }
      final alias = entry['alias'] ?? '';
      if (alias is! String || alias.trim().runes.length > 64) {
        invalid++;
        continue;
      }
      friends.add((card: jsonEncode(entry['card']), alias: alias.trim()));
    }
    return FriendListBackup._(friends, invalid);
  }

  static Uint8List encode(List<ContactView> friends) {
    final entries = [
      for (final friend in friends)
        {
          'card':
              friend.signedCard ??
              (throw StateError('Missing signed contact card')),
          'alias': friend.alias,
        },
    ];
    final bytes = JsonUtf8Encoder('  ')
        .convert({'format': _format, 'version': _version, 'friends': entries});
    _checkSize(bytes.length);
    return Uint8List.fromList(bytes);
  }

  Future<({int added, int existing, int skipped})> mergeInto(
    AccountBridge bridge,
    String ownerId, {
    required bool Function() isCurrent,
  }) async {
    final existingIds = {
      for (final friend in await bridge.contacts()) friend.identityId,
    };
    var added = 0, existing = 0, skipped = _invalid;
    for (final entry in _friends) {
      if (!isCurrent()) break;
      ContactView friend;
      try {
        friend = await bridge.inspectContactCard(entry.card);
      } catch (_) {
        skipped++;
        continue;
      }
      if (!isCurrent()) break;
      if (friend.identityId == ownerId) {
        skipped++;
      } else if (existingIds.contains(friend.identityId)) {
        existing++;
      } else {
        try {
          // Verification belongs to the current identity and stays on-device.
          await bridge.addContact(entry.card, entry.alias);
          existingIds.add(friend.identityId);
          added++;
        } catch (_) {
          skipped++;
        }
      }
    }
    return (added: added, existing: existing, skipped: skipped);
  }

  static void _checkSize(int length) {
    if (length > _maxBytes) {
      throw const FormatException('Friend lists must be 32 MB or smaller.');
    }
  }

  static Future<Uint8List?> pickFile() async {
    final files = await FilePicker.pickFiles(
      dialogTitle: 'Import friends',
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    if (files.isEmpty) return null;
    final file = files.single;
    final length = await file.length();
    if (length != null) _checkSize(length);
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in file.readAsByteStream()) {
      _checkSize(bytes.length + chunk.length);
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }

  static Future<bool> saveFile(Uint8List bytes) async {
    final location = await FilePicker.saveFile(
      dialogTitle: 'Export friends',
      fileName: 'chta-friends.json',
      mimeType: 'application/json',
      bytes: bytes,
    );
    // The browser starts a download without returning a destination URI.
    return kIsWeb || location != null;
  }
}
