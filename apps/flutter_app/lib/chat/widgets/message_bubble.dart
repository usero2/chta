import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../message_timestamp.dart';

class ChatMarkdown extends StatelessWidget {
  const ChatMarkdown({super.key, required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => MarkdownBody(
    data: text,
    selectable: true,
    styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
      p: TextStyle(color: color),
      a: TextStyle(color: color, decoration: TextDecoration.underline),
      code: TextStyle(color: color, fontFamily: 'monospace'),
      codeblockDecoration: BoxDecoration(
        color: color.computeLuminance() > .5
            ? const Color(0xFF202020)
            : const Color(0xFFD5F1CD),
        borderRadius: BorderRadius.circular(4),
      ),
      h1: TextStyle(color: color, fontSize: 26, fontWeight: FontWeight.bold),
      h2: TextStyle(color: color, fontSize: 23, fontWeight: FontWeight.bold),
      h3: TextStyle(color: color, fontSize: 20, fontWeight: FontWeight.bold),
      h4: TextStyle(color: color, fontWeight: FontWeight.bold),
      h5: TextStyle(color: color, fontWeight: FontWeight.bold),
      h6: TextStyle(color: color, fontWeight: FontWeight.bold),
      tableBody: TextStyle(color: color),
      tableHead: TextStyle(color: color, fontWeight: FontWeight.bold),
      blockquote: TextStyle(color: color),
      listBullet: TextStyle(color: color),
    ),
    imageBuilder: (uri, title, alt) =>
        Text(alt ?? '', style: TextStyle(color: color)),
    checkboxBuilder: (checked) => Icon(
      checked ? Icons.check_box_outlined : Icons.check_box_outline_blank,
      color: color,
      size: 18,
    ),
    onTapLink: (text, href, title) async {
      final uri = Uri.tryParse(href ?? '');
      if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
        try {
          await launchUrl(uri);
        } catch (_) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Could not open link.')),
            );
          }
        }
      }
    },
  );
}

class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.text,
    required this.incoming,
    required this.sentAtMilliseconds,
    required this.receivedAtMilliseconds,
    this.onRetry,
    this.content,
    this.bubbleKey,
    this.showReceivedTime = true,
    this.media = false,
  });

  final String text;
  final bool incoming;
  final int? sentAtMilliseconds;
  final int? receivedAtMilliseconds;
  final VoidCallback? onRetry;
  final Widget? content;
  final Key? bubbleKey;
  final bool showReceivedTime;
  final bool media;

  static final _lineBreak = RegExp(r'\r\n?|\n');

  Widget _textContent() {
    final color = incoming ? const Color(0xFFECECEC) : const Color(0xFF0B0B0B);
    final breakAfterPreview = _lineBreak.allMatches(text).skip(19).firstOrNull;
    if (breakAfterPreview == null || breakAfterPreview.end == text.length) {
      return ChatMarkdown(text: text, color: color);
    }
    return _ExpandableMessageText(
      key: ValueKey(text),
      text: text,
      previewEnd: breakAfterPreview.start,
      color: color,
    );
  }

  @override
  Widget build(BuildContext context) {
    final bubble = Flexible(
      child: Container(
        key: bubbleKey,
        constraints: const BoxConstraints(maxWidth: 520),
        padding: media
            ? EdgeInsets.zero
            : const EdgeInsets.symmetric(horizontal: 15, vertical: 11),
        decoration: media
            ? null
            : BoxDecoration(
                color: incoming
                    ? const Color(0xFF2A2A2A)
                    : const Color(0xFF9AE585),
                borderRadius: BorderRadius.circular(18),
              ),
        child: content ?? _textContent(),
      ),
    );
    final times = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: incoming
          ? CrossAxisAlignment.start
          : CrossAxisAlignment.end,
      children: [
        _time(Icons.north_rounded, 'เวลาส่ง', sentAtMilliseconds),
        if (showReceivedTime)
          _time(
            Icons.south_rounded,
            'เวลารับ',
            receivedAtMilliseconds,
            sameDateAs: sentAtMilliseconds,
          ),
        if (onRetry != null)
          IconButton(
            onPressed: onRetry,
            tooltip: 'Retry',
            visualDensity: VisualDensity.compact,
            iconSize: 16,
            icon: const Icon(Icons.refresh),
          ),
      ],
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final metadata = ConstrainedBox(
            constraints: BoxConstraints(maxWidth: constraints.maxWidth * .5),
            child: times,
          );
          return Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: incoming
                ? MainAxisAlignment.start
                : MainAxisAlignment.end,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: incoming
                ? [bubble, const SizedBox(width: 5), metadata]
                : [metadata, const SizedBox(width: 5), bubble],
          );
        },
      ),
    );
  }

  Widget _time(
    IconData icon,
    String label,
    int? milliseconds, {
    int? sameDateAs,
  }) => Tooltip(
    message: '$label: ${formatMessageTimestamp(milliseconds)}',
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          icon,
          size: 12,
          color: const Color(0xFF8E8E93),
          semanticLabel: label,
        ),
        const SizedBox(width: 3),
        Flexible(
          child: Text(
            formatCompactMessageTimestamp(milliseconds, sameDateAs: sameDateAs),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Color(0xFF8E8E93), fontSize: 11),
          ),
        ),
      ],
    ),
  );
}

class _ExpandableMessageText extends StatefulWidget {
  const _ExpandableMessageText({
    super.key,
    required this.text,
    required this.previewEnd,
    required this.color,
  });

  final String text;
  final int previewEnd;
  final Color color;

  @override
  State<_ExpandableMessageText> createState() => _ExpandableMessageTextState();
}

class _ExpandableMessageTextState extends State<_ExpandableMessageText> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      ChatMarkdown(
        text: _expanded
            ? widget.text
            : widget.text.substring(0, widget.previewEnd),
        color: widget.color,
      ),
      TextButton(
        onPressed: () => setState(() => _expanded = !_expanded),
        style: TextButton.styleFrom(
          foregroundColor: widget.color,
          visualDensity: VisualDensity.compact,
        ),
        child: Text(_expanded ? 'Show less' : 'Read more'),
      ),
    ],
  );
}
