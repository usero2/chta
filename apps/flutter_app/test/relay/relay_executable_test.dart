import 'dart:io';

import 'package:cht/relay/relay_executable.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'a clean machine uses the bundled tunnel without a PATH installation',
    () async {
      final tried = <String>[];
      final bundled = [
        'runtime',
        'cloudflared.exe',
      ].join(Platform.pathSeparator);
      final found = await findRelayTunnelExecutable(
        runtimeDirectory: 'runtime',
        programFilesX86: 'other-programs',
        runVersion: (command, args) async {
          tried.add(command);
          expect(args, ['--version']);
          return ProcessResult(
            1,
            command == bundled ? 0 : 1,
            'cloudflared version 2026.11.0',
            '',
          );
        },
      );
      expect(found, bundled);
      expect(tried, [bundled]);
    },
  );
  test(
    'existing installations remain usable if the bundled tool is unavailable',
    () async {
      final found = await findRelayTunnelExecutable(
        runtimeDirectory: 'runtime',
        programFilesX86: 'other-programs',
        runVersion: (command, args) async =>
            ProcessResult(1, command == 'cloudflared' ? 0 : 1, '', ''),
      );
      expect(found, 'cloudflared');
    },
  );
  test('missing dependency asks to reinstall the complete app', () async {
    await expectLater(
      findRelayTunnelExecutable(
        runtimeDirectory: 'runtime',
        programFilesX86: 'other-programs',
        runVersion: (_, _) async => ProcessResult(1, 1, '', ''),
      ),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('Reinstall'),
        ),
      ),
    );
  });
}
