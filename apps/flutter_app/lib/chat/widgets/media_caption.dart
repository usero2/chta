import 'package:flutter/material.dart';

import 'message_bubble.dart';

/// The only colored surface of an image/video message is its optional caption.
class MediaCaption extends StatelessWidget {
  const MediaCaption({super.key, required this.text, required this.incoming});
  final String text;
  final bool incoming;

  @override
  Widget build(BuildContext context) => Container(
    key: const Key('media-caption'),
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    decoration: BoxDecoration(
      borderRadius: const BorderRadius.vertical(bottom: Radius.circular(14)),
      color: incoming ? const Color(0xFF2A2A2A) : const Color(0xFF9AE585),
    ),
    child: ChatMarkdown(
      text: text,
      color: incoming ? const Color(0xFFECECEC) : const Color(0xFF0B0B0B),
    ),
  );
}
