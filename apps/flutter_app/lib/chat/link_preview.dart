import 'dart:convert';

import 'file_offer_cover.dart';

const _marker = '\n\n[chta-link-preview-v1]: ';
final _urlPattern = RegExp(r'''https?://[^\s<>"'`]+''', caseSensitive: false);
final _hostPattern = RegExp(r'^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])$');

bool publicPreviewUrl(Uri? uri) {
  if (uri == null ||
      (uri.scheme != 'https' && uri.scheme != 'http') ||
      uri.userInfo.isNotEmpty ||
      uri.authority.contains('@') ||
      uri.port != (uri.scheme == 'https' ? 443 : 80)) {
    return false;
  }
  final host = uri.host.toLowerCase();
  return host.contains('.') &&
      host.length <= 253 &&
      _hostPattern.hasMatch(host) &&
      RegExp(r'[a-z]').hasMatch(host.split('.').last) &&
      !const [
        '.local',
        '.localhost',
        '.internal',
        '.home',
        '.lan',
      ].any(host.endsWith);
}

Uri? firstPreviewUrl(String text) {
  if (text.length > 16384) return null;
  for (final match in _urlPattern.allMatches(text).take(8)) {
    final source = match[0]!.replaceFirst(RegExp(r'[)\]}>.,;!?]+$'), '');
    if (source.length > 2048) continue;
    final candidate = Uri.tryParse(source);
    if (publicPreviewUrl(candidate)) return candidate;
  }
  return null;
}

String cleanPreviewText(String? source, int max) {
  final text = (source ?? '')
      .replaceAll(RegExp(r'[\x00-\x1f\x7f\s]+'), ' ')
      .trim();
  return String.fromCharCodes(text.runes.take(max));
}

class LinkPreview {
  const LinkPreview({
    required this.url,
    required this.title,
    this.description = '',
    this.cover,
  });

  final Uri url;
  final String title, description;
  final String? cover;
}

String withLinkPreview(String text, LinkPreview preview) {
  // A Markdown reference definition preserves readable links on older clients.
  final payload = jsonEncode({
    'url': preview.url.toString(),
    'title': preview.title,
    'description': preview.description,
    if (preview.cover != null) 'cover': preview.cover,
  });
  return text +
      _marker +
      base64Url.encode(utf8.encode(payload)).replaceAll('=', '');
}

({String text, LinkPreview? preview}) readLinkPreview(String text) {
  final index = text.lastIndexOf(_marker);
  if (index < 0) return (text: text, preview: null);
  final suffix = text.substring(index + _marker.length);
  if (suffix.length > 12000 || !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(suffix)) {
    return (text: text, preview: null);
  }
  final body = text.substring(0, index);
  try {
    final value = jsonDecode(
      utf8.decode(base64Url.decode(base64Url.normalize(suffix))),
    );
    if (value is! Map || value['url'] is! String) {
      return (text: body, preview: null);
    }
    final url = firstPreviewUrl(body);
    if (url == null || value['url'] != url.toString()) {
      return (text: body, preview: null);
    }
    final title = cleanPreviewText(value['title'] as String?, 140);
    final description = cleanPreviewText(value['description'] as String?, 260);
    final cover = value['cover'];
    return (
      text: body,
      preview: LinkPreview(
        url: url,
        title: title.isEmpty ? url.host : title,
        description: description,
        cover: cover is String && cover.length <= maxFileOfferCoverEncodedLength
            ? cover
            : null,
      ),
    );
  } catch (_) {
    return (text: body, preview: null);
  }
}
