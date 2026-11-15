import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'mount_path.dart';

final _mount = AppMount(
  const String.fromEnvironment('CHT_APP_BASE_PATH', defaultValue: '').isNotEmpty
      ? const String.fromEnvironment('CHT_APP_BASE_PATH')
      : Uri.parse(web.document.baseURI).path,
);

String readCurrentPath() => _mount.internal(web.window.location.pathname);

void writePath(String path, {required bool replace}) {
  if (replace) {
    web.window.history.replaceState(null, '', _mount.external(path));
  } else {
    web.window.history.pushState(null, '', _mount.external(path));
  }
}

void watchPath(void Function(String path) onChanged) {
  web.window.addEventListener(
    'popstate',
    ((web.Event _) => onChanged(readCurrentPath())).toJS,
  );
}
