import 'dart:async';

import 'package:cht/courier/courier_journal.dart';
import 'package:cht/groups/group_blob_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

class Disk implements GroupBlobBridge {
  final values = <String, String>{};
  int saves = 0;
  int? failAt;
  bool failDelete = false;
  Future<void> Function(int, String)? beforeSave;
  @override
  Future<String?> loadGroupBlob(String ownerId, String key) async =>
      values[key];
  @override
  Future<void> saveGroupBlob(String ownerId, String key, String value) async {
    if (++saves == failAt) throw StateError('disk full');
    await beforeSave?.call(saves, key);
    values[key] = value;
  }

  @override
  Future<void> deleteGroupBlob(String ownerId, String key) async {
    if (failDelete) throw StateError('delete failed');
    values.remove(key);
  }
}

void main() {
  test('every failed commit preserves old readable pages and restart removes only staged copies', () async {
    for (var fail = 1; fail <= 8; fail++) {
      final disk = Disk(),
          journal = CourierJournal(
            ownerId: 'owner',
            namespace: 'courier_send',
            storage: Disk(),
          );
      final live = CourierJournal(
        ownerId: 'owner',
        namespace: 'courier_send',
        storage: disk,
      );
      await live.initialize();
      await live.commit({'job': 'old', 'piece': 'ciphertext'}, {});
      disk.failAt = disk.saves + fail;
      try {
        await live.commit({'job': 'new', 'piece': 'new ciphertext'}, {});
      } catch (_) {}
      disk.failAt = null;
      final reopened = CourierJournal(
        ownerId: 'owner',
        namespace: 'courier_send',
        storage: disk,
      );
      await reopened.initialize();
      final value = await reopened.read('job');
      expect(['old', 'new'], contains(value));
      expect(
        await reopened.read('piece'),
        value == 'old' ? 'ciphertext' : 'new ciphertext',
      );
      expect(
        disk.values.keys.every((k) => k.startsWith('courier_send_')),
        isTrue,
      );
      await journal.initialize(); // Independent storage cannot inherit another journal's entries.
      expect(await journal.read('job'), isNull);
    }
  });
  test('committed removal is durable even if cleanup fails and old data never revives', () async {
    final disk = Disk(),
        live = CourierJournal(
          ownerId: 'owner',
          namespace: 'courier_host',
          storage: Disk(),
        );
    await live.initialize();
    final journal = CourierJournal(
      ownerId: 'owner',
      namespace: 'courier_host',
      storage: disk,
    );
    await journal.initialize();
    await journal.commit({'package': 'cipher'}, {});
    disk.failDelete = true;
    await journal.commit({}, {'package'});
    expect(await journal.read('package'), isNull);
    disk.failDelete = false;
    final reopened = CourierJournal(
      ownerId: 'owner',
      namespace: 'courier_host',
      storage: disk,
    );
    await reopened.initialize();
    expect(await reopened.read('package'), isNull);
  });
  test(
    'owner shutdown during a write cannot acknowledge or revive the service',
    () async {
      var active = true;
      final disk = Disk(),
          journal = CourierJournal(
            ownerId: 'owner',
            namespace: 'courier_send',
            storage: Disk(),
          );
      await journal.initialize();
      final guarded = CourierJournal(
        ownerId: 'owner',
        namespace: 'courier_host',
        storage: disk,
        isCurrent: () => active,
      );
      await guarded.initialize();
      final reached = Completer<void>(), release = Completer<void>();
      disk.beforeSave = (number, key) async {
        if (number == 2) {
          reached.complete();
          await release.future;
        }
      };
      final pending = guarded.commit({'job': 'private'}, {});
      final checked = expectLater(pending, throwsStateError);
      await reached.future;
      active = false;
      guarded.close();
      release.complete();
      await checked;
      active = true;
      disk.beforeSave = null;
      final reopened = CourierJournal(
        ownerId: 'owner',
        namespace: 'courier_host',
        storage: disk,
      );
      await reopened.initialize();
      expect(await reopened.read('job'), isNull);
    },
  );
}
