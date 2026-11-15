/// Maps browser paths to the app's existing, root-relative route names.
class AppMount {
  const AppMount(this.basePath);
  final String basePath;
  String get prefix {
    final path = basePath.endsWith('/')
        ? basePath.substring(0, basePath.length - 1)
        : basePath;
    return path.startsWith('/') &&
            !path.startsWith('//') &&
            !path.contains('..') &&
            !path.contains('?') &&
            !path.contains('#')
        ? path
        : '';
  }

  factory AppMount.fromBaseUri(Uri uri) => AppMount(uri.path);
  String internal(String path) {
    if (prefix.isEmpty) return path;
    if (path == prefix || path == '$prefix/') return '/';
    return path.startsWith('$prefix/') ? path.substring(prefix.length) : '/';
  }

  String external(String path) =>
      '$prefix${path.startsWith('/') && !path.startsWith('//') && !path.contains('\\') ? path : '/'}';
}
