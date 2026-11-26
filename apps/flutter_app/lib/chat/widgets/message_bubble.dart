import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../message_timestamp.dart';
import 'message_action_menu.dart';

class ChatMarkdown extends StatelessWidget {
  const ChatMarkdown({super.key, required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final hasMessageMenu =
        context.dependOnInheritedWidgetOfExactType<_MessageActionScope>() !=
        null;
    return MarkdownBody(
      data: text,
      selectable:
          !hasMessageMenu ||
          (defaultTargetPlatform != TargetPlatform.android &&
              defaultTargetPlatform != TargetPlatform.iOS),
      contextMenuBuilder: hasMessageMenu
          ? null
          : (_, editor) => AdaptiveTextSelectionToolbar.editableText(
              editableTextState: editor,
            ),
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
}

class _MessageActionScope extends InheritedWidget {
  const _MessageActionScope({required super.child});

  @override
  bool updateShouldNotify(_MessageActionScope oldWidget) => false;
}

enum MessageDeliveryIndicator { pending, delivered }

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
    this.showTime = true,
    this.deliveryIndicator,
    this.deliveryDetail,
    this.media = false,
    this.actions,
  });

  final String text;
  final bool incoming;
  final int? sentAtMilliseconds;
  final int? receivedAtMilliseconds;
  final VoidCallback? onRetry;
  final Widget? content;
  final Key? bubbleKey;
  final bool showTime;
  final MessageDeliveryIndicator? deliveryIndicator;
  final String? deliveryDetail;
  final bool media;
  final MessageActionMenu? actions;

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
    final time = visibleMessageTime(sentAtMilliseconds, receivedAtMilliseconds);
    final clock = showTime
        ? formatCompactMessageTimestamp(time?.millisecondsSinceEpoch)
        : null;
    final detailsRows = [
      if (messageDateTime(sentAtMilliseconds) != null)
        'เวลาส่ง ${formatMessageTimestamp(sentAtMilliseconds)}',
      if (messageDateTime(receivedAtMilliseconds) != null)
        'เวลารับ ${formatMessageTimestamp(receivedAtMilliseconds)}',
      ?deliveryDetail,
    ];
    final details = detailsRows.isEmpty ? null : detailsRows.join('\n');

    final container = Container(
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
    );
    final menu =
        actions ??
        (details == null ? null : const MessageActionMenu(showReply: false));
    Widget withDetails(Widget child) => details == null
        ? child
        : Tooltip(
            message: details,
            triggerMode: TooltipTriggerMode.manual,
            child: child,
          );
    final bubble = Flexible(
      child: menu == null
          ? container
          : Builder(
              builder: (anchor) => Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: (event) {
                  if (event.kind == PointerDeviceKind.mouse &&
                      event.buttons == kSecondaryMouseButton) {
                    menu.show(
                      anchor,
                      pointer: event.position,
                      details: details,
                    );
                  }
                },
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onLongPressStart: (event) => menu.show(
                    anchor,
                    pointer: event.globalPosition,
                    details: details,
                  ),
                  child: _MessageActionScope(
                    child: clock == null ? withDetails(container) : container,
                  ),
                ),
              ),
            ),
    );
    final style = Theme.of(context).textTheme.labelSmall
        ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);
    final info = Wrap(
      spacing: 2,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (clock != null || deliveryIndicator != null)
          withDetails(
            Wrap(
              spacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (clock != null) Text(clock, style: style),
                if (deliveryIndicator case final status?)
                  Icon(
                    status == MessageDeliveryIndicator.delivered
                        ? Icons.done_all
                        : Icons.schedule,
                    size: 14,
                    color: style?.color,
                    semanticLabel: status == MessageDeliveryIndicator.delivered
                        ? 'Delivered'
                        : 'Waiting for delivery',
                  ),
              ],
            ),
          ),
        if (menu != null)
          Builder(
            builder: (anchor) => IconButton(
              key: menu.buttonKey,
              onPressed: () => menu.show(anchor, details: details),
              tooltip: 'Message actions',
              style: IconButton.styleFrom(
                minimumSize: const Size(32, 32),
                padding: EdgeInsets.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              icon: const Icon(Icons.more_horiz, size: 18),
            ),
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
            child: info,
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
