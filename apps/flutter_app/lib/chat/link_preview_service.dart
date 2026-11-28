import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:html/parser.dart' as html;
import 'package:http/http.dart' as http;

import 'file_offer_cover.dart';
import 'link_preview.dart';
import 'link_preview_client.dart';

class LinkPreviewService {
  LinkPreviewService({http.Client? client})
    : _client = client ?? createLinkPreviewClient();

  final http.Client _client;
  final _cache = <Uri, Future<LinkPreview?>>{};
  bool _closed = false;

  Future<String> prepare(
    String source, {
    required bool Function(String) fits,
  }) async {
    final text = readLinkPreview(source).text;
    final url = firstPreviewUrl(text);
    if (_closed || url == null || !fits(text)) return text;
    final preview = await load(url);
    if (preview == null || _closed) return text;
    final encoded = withLinkPreview(text, preview);
    if (fits(encoded)) return encoded;
    final small = withLinkPreview(
      text,
      LinkPreview(
        url: url,
        title: preview.title,
        description: preview.description,
      ),
    );
    return fits(small) ? small : text;
  }

  Future<LinkPreview?> load(Uri url) {
    if (_closed || !publicPreviewUrl(url)) return Future.value();
    final cached = _cache.remove(url);
    if (_cache.length >= 32) _cache.remove(_cache.keys.first);
    return _cache[url] = cached ?? _load(url);
  }

  Future<LinkPreview?> _load(Uri url) async {
    final abort = Completer<void>();
    try {
      return await _preview(
        url,
        abort.future,
      ).timeout(const Duration(seconds: 3));
    } catch (_) {
      return null;
    } finally {
      abort.complete();
    }
  }

  Future<LinkPreview?> _preview(Uri url, Future<void> abort) async {
    final source = url.removeFragment();
    final pageFuture = _page(
      source,
      abort,
    ).timeout(const Duration(milliseconds: 1500), onTimeout: () => null);
    final embedFuture = _embed(
      source,
      abort,
    ).timeout(const Duration(milliseconds: 1500), onTimeout: () => null);
    final page = await pageFuture, embed = await embedFuture;
    final title = cleanPreviewText(embed?.title ?? page?.title, 140);
    final description = cleanPreviewText(
      page?.description ?? embed?.description,
      260,
    );
    final image = embed?.image ?? page?.image ?? _youtubePoster(url);
    final thumbnail = image == null ? null : await _thumbnail(image, abort);
    if (title.isEmpty && description.isEmpty && thumbnail == null) return null;
    return LinkPreview(
      url: url,
      title: title.isEmpty ? url.host : title,
      description: description,
      cover: thumbnail,
    );
  }

  Future<_Metadata?> _page(Uri url, Future<void> abort) async {
    try {
      final result = await _get(
        url,
        abort,
        limit: 192 * 1024,
        type: 'text/html',
        partial: true,
      );
      if (result == null) return null;
      final document = html.parse(
        utf8.decode(result.bytes, allowMalformed: true),
      );
      final meta = <String, String>{};
      for (final entry in document.head?.querySelectorAll('meta') ?? const []) {
        final attributes = entry.attributes;
        final key = (attributes['property'] ?? attributes['name'])
            ?.toLowerCase();
        final content = attributes['content']?.trim();
        if (key != null && content != null && content.isNotEmpty) {
          meta.putIfAbsent(key, () => content);
        }
      }
      final title =
          meta['og:title'] ??
          meta['twitter:title'] ??
          document.querySelector('title')?.text;
      final description =
          meta['og:description'] ??
          meta['twitter:description'] ??
          meta['description'];
      final image = _resolve(
        result.url,
        meta['og:image:secure_url'] ??
            meta['og:image'] ??
            meta['twitter:image'],
      );
      return _Metadata(title, description, image);
    } catch (_) {
      return null;
    }
  }

  Future<_Metadata?> _embed(Uri url, Future<void> abort) async {
    final host = url.host;
    final Uri endpoint;
    if (host == 'youtu.be' ||
        host == 'youtube.com' ||
        host.endsWith('.youtube.com')) {
      endpoint = Uri.https('www.youtube.com', '/oembed', {
        'url': url.toString(),
        'format': 'json',
      });
    } else if (host == 'tiktok.com' || host.endsWith('.tiktok.com')) {
      endpoint = Uri.https('www.tiktok.com', '/oembed', {
        'url': url.toString(),
      });
    } else {
      return null;
    }
    try {
      final response = await _get(
        endpoint,
        abort,
        limit: 64 * 1024,
        type: 'application/json',
      );
      if (response == null) return null;
      final value = jsonDecode(utf8.decode(response.bytes));
      if (value is! Map) return null;
      // Only parse metadata. The HTML embed is never executed or rendered.
      return _Metadata(
        value['title'] as String?,
        value['description'] as String?,
        _resolve(response.url, value['thumbnail_url'] as String?),
      );
    } catch (_) {
      return null;
    }
  }

  Uri? _youtubePoster(Uri url) {
    final host = url.host, path = url.pathSegments;
    final String? id;
    if (host == 'youtu.be' && path.length == 1) {
      id = path.first;
    } else if (host == 'youtube.com' || host.endsWith('.youtube.com')) {
      id = path.length == 2 && ['shorts', 'live', 'embed'].contains(path.first)
          ? path.last
          : url.queryParameters['v'];
    } else {
      return null;
    }
    return id != null && RegExp(r'^[a-zA-Z0-9_-]{11}$').hasMatch(id)
        ? Uri.https('i.ytimg.com', '/vi/$id/mqdefault.jpg')
        : null;
  }

  Future<String?> _thumbnail(Uri url, Future<void> abort) async {
    try {
      final response = await _get(
        url,
        abort,
        limit: 512 * 1024,
        type: 'image/',
      );
      if (response == null) return null;
      return await encodePreviewJpeg(
        response.bytes,
        maxBytes: 2200,
        maxPixels: 12000000,
      );
    } catch (_) {
      return null;
    }
  }

  Uri? _resolve(Uri base, String? source) {
    if (source == null || source.length > 2048) return null;
    final resolved = base.resolve(source);
    return publicPreviewUrl(resolved) ? resolved.removeFragment() : null;
  }

  Future<({Uri url, Uint8List bytes})?> _get(
    Uri url,
    Future<void> abort, {
    required int limit,
    required String type,
    bool partial = false,
  }) async {
    for (var redirects = 0; redirects <= 3; redirects++) {
      if (_closed || !publicPreviewUrl(url)) return null;
      final request = http.AbortableRequest('GET', url, abortTrigger: abort)
        ..followRedirects = false;
      final response = await _client.send(request);
      final status = response.statusCode;
      final mime = response.headers['content-type']?.toLowerCase();
      if (status != 200 || mime?.startsWith(type) != true) {
        final stream = response.stream.listen((_) {});
        await stream.cancel();
        final redirect = status >= 300 && status < 400
            ? _resolve(url, response.headers['location'])
            : null;
        if (redirect == null ||
            url.scheme == 'https' && redirect.scheme != 'https') {
          return null;
        }
        url = redirect;
        continue;
      }
      final bytes = BytesBuilder(copy: false);
      await for (final block in response.stream) {
        final remaining = limit - bytes.length;
        if (block.length > remaining && !partial) return null;
        bytes.add(
          block.length > remaining ? block.sublist(0, remaining) : block,
        );
        if (partial && bytes.length == limit) break;
      }
      return (url: url, bytes: bytes.takeBytes());
    }
    return null;
  }

  void dispose() {
    _closed = true;
    _cache.clear();
    _client.close();
  }
}

class _Metadata {
  const _Metadata(this.title, this.description, this.image);
  final String? title, description;
  final Uri? image;
}
