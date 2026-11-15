import 'chat_attachment.dart';

/// Presentation and integrity metadata only; file bytes live in the cache.
class AttachmentRef {
  AttachmentRef({
    required this.name,
    required this.mimeType,
    required this.size,
    required this.digest,
    this.chunkedId,
    this.chunkSize,
    this.caption,
    this.groupId,
    this.groupIndex,
    this.groupCount,
  }) {
    if ((chunkedId == null) != (chunkSize == null)) {
      throw const FormatException('Incomplete chunked attachment reference');
    }
    if (isChunked) {
      ChatAttachment.validateStreamedMetadata(name, mimeType, size);
      if (!RegExp(r'^[A-Za-z0-9_-]{16,96}$').hasMatch(chunkedId!) ||
          chunkSize! < 1 ||
          chunkSize! > 1024 * 1024) {
        throw const FormatException('Invalid chunked attachment reference');
      }
    } else {
      ChatAttachment.validateMetadata(name, mimeType, size);
    }
    ChatAttachment.validatePresentation(
      caption,
      groupId,
      groupIndex,
      groupCount,
    );
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(digest)) {
      throw const FormatException('Invalid attachment digest');
    }
  }
  final String name, mimeType, digest;
  final int size;
  final String? chunkedId;
  final int? chunkSize;
  bool get isChunked => chunkedId != null;
  final String? caption, groupId;
  final int? groupIndex, groupCount;
  String get kind => mimeType.toLowerCase().split('/').first;
  Map<String, Object?> toJson() => {
    'name': name,
    'mimeType': mimeType,
    'size': size,
    'digest': digest,
    if (chunkedId != null) 'chunkedId': chunkedId,
    if (chunkSize != null) 'chunkSize': chunkSize,
    if (caption != null) 'caption': caption,
    if (groupId != null) 'groupId': groupId,
    if (groupIndex != null) 'groupIndex': groupIndex,
    if (groupCount != null) 'groupCount': groupCount,
  };
  factory AttachmentRef.fromJson(Map<String, dynamic> value) {
    ChatAttachment.validatePresentation(
      value['caption'],
      value['groupId'],
      value['groupIndex'],
      value['groupCount'],
    );
    if (value['name'] is! String ||
        value['mimeType'] is! String ||
        value['size'] is! int ||
        value['digest'] is! String ||
        (value['chunkedId'] != null && value['chunkedId'] is! String) ||
        (value['chunkSize'] != null && value['chunkSize'] is! int)) {
      throw const FormatException('Invalid attachment reference');
    }
    return AttachmentRef(
      name: value['name'] as String,
      mimeType: value['mimeType'] as String,
      size: value['size'] as int,
      digest: value['digest'] as String,
      chunkedId: value['chunkedId'] as String?,
      chunkSize: value['chunkSize'] as int?,
      caption: value['caption'] as String?,
      groupId: value['groupId'] as String?,
      groupIndex: value['groupIndex'] as int?,
      groupCount: value['groupCount'] as int?,
    );
  }
}
