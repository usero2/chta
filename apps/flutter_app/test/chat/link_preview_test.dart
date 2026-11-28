import 'dart:convert';

import 'package:cht/chat/link_preview.dart';
import 'package:cht/chat/link_preview_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:markdown/markdown.dart' as markdown;

void main() {
  const text = 'Look at https://example.com/article';
  final url = Uri.parse('https://example.com/article');

  test(
    'metadata is encrypted with the text and keeps its old Markdown rendering',
    () {
      final wire = withLinkPreview(
        text,
        LinkPreview(
          url: url,
          title: 'Example title',
          description: 'Example description',
        ),
      );
      final result = readLinkPreview(wire);
      expect(result.text, text);
      expect(result.preview?.title, 'Example title');
      final legacy = markdown.Document(
        extensionSet: markdown.ExtensionSet.gitHubFlavored,
      ).parseLines(wire.split('\n'));
      expect(legacy.map((node) => node.textContent).join(), text);
      expect(
        readLinkPreview(wire.replaceFirst('example.com', 'example.org'))
            .preview,
        isNull,
      );
    },
  );

  test(
    'extracts public metadata and blocks redirects to private addresses',
    () async {
      final service = LinkPreviewService(
        client: MockClient((request) async {
          expect(request.followRedirects, isFalse);
          return request.url.path == '/blocked'
              ? http.Response(
                  '',
                  302,
                  headers: {'location': 'http://127.0.0.1/private'},
                )
              : http.Response(
                  '''<title>Fallback</title>
              <meta property="og:title" content="Hello &amp; goodbye">
              <meta name="description" content="A short description">
              <meta property="og:image" content="http://169.254.169.254/file">''',
                  200,
                  headers: {'content-type': 'text/html; charset=utf-8'},
                );
        }),
      );
      addTearDown(service.dispose);
      final preview = await service.load(url);
      expect(preview?.title, 'Hello & goodbye');
      expect(preview?.description, 'A short description');
      expect(preview?.cover, isNull);
      expect(await service.load(url.replace(path: '/blocked')), isNull);
    },
  );
  test(
    'uses provider oEmbed metadata and keeps URL fragments out of requests',
    () async {
      final video = Uri.parse(
        'https://www.tiktok.com/@fixture/video/123#private',
      );
      final service = LinkPreviewService(
        client: MockClient((request) async {
          expect(request.url.toString(), isNot(contains('private')));
          if (request.url.path != '/oembed') return http.Response('', 403);
          expect(request.url.host, 'www.tiktok.com');
          expect(
            request.url.queryParameters['url'],
            video.removeFragment().toString(),
          );
          return http.Response(
            jsonEncode({
              'title': 'Video caption',
              'description': 'Video description',
              'html': '<script>remote embed markup</script>',
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      addTearDown(service.dispose);
      final prepared = await service.prepare(
        video.toString(),
        fits: (text) => text.length < 4096,
      );
      final decoded = readLinkPreview(prepared);
      expect(decoded.text, video.toString());
      expect(decoded.preview?.title, 'Video caption');
      expect(decoded.preview?.description, 'Video description');
      expect(decoded.preview?.url, video);
    },
  );
}
