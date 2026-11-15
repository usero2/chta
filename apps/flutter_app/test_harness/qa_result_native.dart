import 'dart:io';
import 'dart:convert';
import 'dart:async';

import 'package:path_provider/path_provider.dart';

void writeQaResult(Map<String, Object?> value) {
  final path = Platform.environment['CHT_QA_RESULT'];
  if (path != null) File(path).writeAsStringSync(jsonEncode(value));
  if (path == null) {
    unawaited(
      () async {
        final directory = await getTemporaryDirectory();
        await File('${directory.path}/cht-qa-result.json')
            .writeAsString(jsonEncode(value), flush: true);
      }().catchError((Object _) {
        /* The log still records diagnostic output. */
      }),
    );
  }
}
