import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

class ProfileAvatar extends StatefulWidget {
  const ProfileAvatar({
    required this.name,
    this.avatarBase64 = '',
    this.bytes,
    this.radius = 20,
    this.selected = false,
    super.key,
  });
  final String name;
  final String avatarBase64;
  final Uint8List? bytes;
  final double radius;
  final bool selected;

  @override
  State<ProfileAvatar> createState() => _ProfileAvatarState();
}

class _ProfileAvatarState extends State<ProfileAvatar> {
  Uint8List? decoded;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  @override
  void didUpdateWidget(covariant ProfileAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.avatarBase64 != widget.avatarBase64 ||
        oldWidget.bytes != widget.bytes) {
      _decode();
    }
  }

  void _decode() {
    decoded = widget.bytes;
    if (decoded != null || widget.avatarBase64.isEmpty) return;
    if (widget.avatarBase64.length > 1368) return;
    try {
      decoded = base64Decode(widget.avatarBase64);
    } on FormatException {
      decoded = null;
    }
  }

  Widget _fallback() => ColoredBox(
    color: widget.selected ? const Color(0xFF9AE585) : const Color(0xFF3A3A3C),
    child: Center(
      child: Text(
        widget.name.trim().isEmpty
            ? '?'
            : widget.name.trim().characters.first.toUpperCase(),
        style: TextStyle(
          color: widget.selected ? const Color(0xFF0B0B0B) : Colors.white,
          fontSize: widget.radius * 0.8,
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => ClipOval(
    child: SizedBox.square(
      dimension: widget.radius * 2,
      child: decoded == null
          ? _fallback()
          : Image.memory(
              decoded!,
              fit: BoxFit.cover,
              cacheWidth: 256,
              cacheHeight: 256,
              semanticLabel: '${widget.name} avatar',
              errorBuilder: (_, _, _) => _fallback(),
            ),
    ),
  );
}
