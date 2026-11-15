import 'dart:convert';
import 'dart:typed_data';

import 'attachment_source.dart';

class ChatAttachment {
  static const int relayMaxBytes = 25 * 1024 * 1024;
  static const int maxBytes = 100 * 1024 * 1024;
  static const int maxStreamedBytes = 10 * 1024 * 1024 * 1024;
  final String name;
  final String mimeType;
  final Uint8List? _bytes;
  final AttachmentSource? source;
  Uint8List get bytes =>
      _bytes ??
      (throw StateError('Streamed attachment has no in-memory bytes'));
  int get size => source?.length ?? _bytes!.length;
  bool get isStreamed => source != null;
  final String? caption, groupId;
  final int? groupIndex, groupCount;

  ChatAttachment({
    required this.name,
    required this.mimeType,
    required Uint8List bytes,
    this.caption,
    this.groupId,
    this.groupIndex,
    this.groupCount,
  }) : _bytes = _copyValidated(name, mimeType, bytes),
       source = null {
    validatePresentation(caption, groupId, groupIndex, groupCount);
  }

  /// Takes ownership of [bytes]; the caller must not mutate it afterward.
  ChatAttachment.fromOwnedBytes({
    required this.name,
    required this.mimeType,
    required Uint8List bytes,
    this.caption,
    this.groupId,
    this.groupIndex,
    this.groupCount,
  }) : _bytes = _ownedValidated(name, mimeType, bytes),
       source = null {
    validatePresentation(caption, groupId, groupIndex, groupCount);
  }

  ChatAttachment.fromSource({
    required this.name,
    required this.mimeType,
    required AttachmentSource source,
    this.caption,
    this.groupId,
    this.groupIndex,
    this.groupCount,
  }) : source = source,
       _bytes = null {
    validateStreamedMetadata(name, mimeType, source.length);
    if (source.key.isEmpty) {
      throw const FormatException('Invalid attachment source');
    }
    validatePresentation(caption, groupId, groupIndex, groupCount);
  }

  Stream<List<int>> openRead({int start = 0, int? end}) {
    final last = end ?? size;
    if (start < 0 || last < start || last > size) {
      throw RangeError.range(last, start, size);
    }
    if (source != null) return source!.openRead(start: start, end: last);
    return Stream.value(_bytes!.sublist(start, last));
  }

  ChatAttachment withPresentation({
    String? caption,
    String? groupId,
    int? groupIndex,
    int? groupCount,
  }) => isStreamed
      ? ChatAttachment.fromSource(
          name: name,
          mimeType: mimeType,
          source: source!,
          caption: caption,
          groupId: groupId,
          groupIndex: groupIndex,
          groupCount: groupCount,
        )
      : ChatAttachment.fromOwnedBytes(
          name: name,
          mimeType: mimeType,
          bytes: bytes,
          caption: caption,
          groupId: groupId,
          groupIndex: groupIndex,
          groupCount: groupCount,
        );

  static void validatePresentation(
    Object? caption,
    Object? groupId,
    Object? index,
    Object? count,
  ) {
    if (caption != null &&
        (caption is! String || utf8.encode(caption).length > 512)) {
      throw const FormatException('Caption must be at most 512 bytes');
    }
    if (groupId == null && index == null && count == null) return;
    if (groupId is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(groupId) ||
        index is! int ||
        count is! int ||
        count < 1 ||
        count > 5 ||
        index < 0 ||
        index >= count) {
      throw const FormatException('Invalid media group');
    }
  }

  Map<String, Object?> get presentationJson => {
    if (caption != null) 'caption': caption,
    if (groupId != null) 'groupId': groupId,
    if (groupIndex != null) 'groupIndex': groupIndex,
    if (groupCount != null) 'groupCount': groupCount,
  };

  static Uint8List _ownedValidated(
    String name,
    String mimeType,
    Uint8List bytes,
  ) {
    validateMetadata(name, mimeType, bytes.length);
    return bytes.asUnmodifiableView();
  }

  static Uint8List _copyValidated(
    String name,
    String mimeType,
    Uint8List bytes,
  ) {
    validateMetadata(name, mimeType, bytes.length);
    return Uint8List.fromList(bytes).asUnmodifiableView();
  }

  static void validateMetadata(String name, String mimeType, int size) {
    validateStreamedMetadata(name, mimeType, size);
    if (size > maxBytes) {
      throw const FormatException('Invalid attachment metadata');
    }
  }

  static void validateStreamedMetadata(String name, String mimeType, int size) {
    if (name.isEmpty ||
        name.length > 255 ||
        name == '.' ||
        name == '..' ||
        RegExp(r'[\\/\x00-\x1f\x7f]').hasMatch(name) ||
        mimeType.length > 127 ||
        !RegExp(r'^[A-Za-z0-9!#$&^_.+-]+/[A-Za-z0-9!#$&^_.+-]+$')
            .hasMatch(mimeType) ||
        size < 0 ||
        size > maxStreamedBytes) {
      throw const FormatException('Invalid attachment metadata');
    }
  }

  String get kind {
    final type = mimeType.toLowerCase();
    if (type.startsWith('image/')) return 'image';
    if (type.startsWith('audio/')) return 'audio';
    if (type.startsWith('video/')) return 'video';
    return 'file';
  }

  String get previewLabel => '[$kind] $name';
  Map<String, dynamic> toJson() => {
    'name': name,
    'mimeType': mimeType,
    'bytes': base64Encode(bytes),
    ...presentationJson,
  };
  factory ChatAttachment.fromJson(Map<String, dynamic> json) {
    final name = json['name'];
    final mime = json['mimeType'];
    final data = json['bytes'];
    validatePresentation(
      json['caption'],
      json['groupId'],
      json['groupIndex'],
      json['groupCount'],
    );
    if (name is! String ||
        mime is! String ||
        data is! String ||
        data.length > ((maxBytes + 2) ~/ 3) * 4) {
      throw const FormatException('Invalid attachment');
    }
    return ChatAttachment(
      name: name,
      mimeType: mime,
      bytes: base64Decode(data),
      caption: json['caption'] as String?,
      groupId: json['groupId'] as String?,
      groupIndex: json['groupIndex'] as int?,
      groupCount: json['groupCount'] as int?,
    );
  }
}
