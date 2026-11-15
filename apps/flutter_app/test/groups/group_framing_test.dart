import 'dart:convert';

import 'package:cht/groups/group_framing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const session = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      id = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
  test(
    'ciphertext fragments reassemble out of order once within wire budget',
    () {
      final source = 'A' * 60000;
      final parts = fragmentGroupCiphertext(session, id, source);
      expect(
        parts.every((p) => utf8.encode(jsonEncode(p)).length <= 16384),
        isTrue,
      );
      final receiver = GroupFrameAssembler();
      String? result;
      for (final part in parts.reversed) {
        result = receiver.add(part, session, 0) ?? result;
      }
      expect(result, source);
      expect(receiver.add(parts.first, session, 1), isNull);
    },
  );
  test(
    'wrong session, conflicting duplicate, oversized and capacity reject',
    () {
      final parts = fragmentGroupCiphertext(session, id, 'A' * 20000);
      final receiver = GroupFrameAssembler();
      expect(
        () => receiver.add(parts.first, 'c' * 32, 0),
        throwsFormatException,
      );
      receiver.add(parts.first, session, 0);
      expect(
        () => receiver.add({...parts.first, 'data': 'B' * 12000}, session, 1),
        throwsFormatException,
      );
      expect(
        () => fragmentGroupCiphertext(session, id, 'A' * 65537),
        throwsFormatException,
      );
      expect(
        () => receiver.add({...parts.first, 'n': 100000}, session, 1),
        throwsFormatException,
      );
      receiver.add(parts.first, session, 1);
      for (var i = 1; i < 4; i++) {
        receiver.add(
          {...parts.first, 'id': i.toRadixString(16).padLeft(32, '0')},
          session,
          1,
        );
      }
      expect(
        () => receiver.add({...parts.first, 'id': 'f' * 32}, session, 2),
        throwsStateError,
      );
      expect(
        receiver.add({...parts.first, 'id': 'f' * 32}, session, 16000),
        isNull,
      );
    },
  );
}
