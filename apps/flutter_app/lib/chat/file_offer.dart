import 'dart:convert';

import 'chat_attachment.dart';

const fileOfferCapability = 'file-offers-v1';
const _offerPrefix = 'chtfo1_offer_';
const _decisionPrefix = 'chtfo1_choice_';
final _fileId = RegExp(r'^[A-Za-z0-9_-]{1,100}$');
final _digest = RegExp(r'^[a-f0-9]{64}$');
final _base64 = RegExp(r'^[A-Za-z0-9+/]+={0,2}$');

bool isFileOfferEvent(String id) =>
    id.startsWith(_offerPrefix) || id.startsWith(_decisionPrefix);

class FileOffer {
  FileOffer({
    required this.fileId,
    required this.name,
    required this.mimeType,
    required this.size,
    required this.digest,
    this.caption,
    this.cover,
  }) {
    ChatAttachment.validateStreamedMetadata(name, mimeType, size);
    ChatAttachment.validatePresentation(caption, null, null, null);
    if (!_fileId.hasMatch(fileId)) {
      throw const FormatException('Invalid transfer ID');
    }
    if (!_digest.hasMatch(digest)) {
      throw const FormatException('Invalid file offer');
    }
    if (cover != null && (cover!.length > 6828 || !_base64.hasMatch(cover!))) {
      throw const FormatException('Invalid file cover');
    }
  }

  final String fileId, name, mimeType, digest;
  final int size;
  final String? caption, cover;

  static String messageId(String fileId) => '$_offerPrefix$fileId';

  String encode() => jsonEncode({
    'name': name,
    'mime': mimeType,
    'size': size,
    'digest': digest,
    if (caption != null) 'caption': caption,
    if (cover != null) 'cover': cover,
  });

  static FileOffer? decode(String id, String text) {
    if (!id.startsWith(_offerPrefix) || text.length > 12000) return null;
    try {
      final value = jsonDecode(text) as Map<String, dynamic>;
      return FileOffer(
        fileId: id.substring(_offerPrefix.length),
        name: value['name'] as String,
        mimeType: value['mime'] as String,
        size: value['size'] as int,
        digest: value['digest'] as String,
        caption: value['caption'] as String?,
        cover: value['cover'] as String?,
      );
    } catch (_) {
      return null;
    }
  }

  bool matches({
    required Object? name,
    required Object? mimeType,
    required Object? size,
    required Object? digest,
  }) =>
      this.name == name &&
      this.mimeType == mimeType &&
      this.size == size &&
      this.digest == digest;
}

class FileOfferDecision {
  const FileOfferDecision(this.fileId, this.digest, this.accepted);

  final String fileId, digest;
  final bool accepted;

  static String messageId(String fileId) => '$_decisionPrefix$fileId';

  String encode() => jsonEncode({'digest': digest, 'accepted': accepted});

  static FileOfferDecision? decode(String id, String text) {
    if (!id.startsWith(_decisionPrefix) || text.length > 180) return null;
    try {
      final fileId = id.substring(_decisionPrefix.length);
      final value = jsonDecode(text) as Map<String, dynamic>;
      final digest = value['digest'] as String;
      if (!_fileId.hasMatch(fileId) || !_digest.hasMatch(digest)) return null;
      return FileOfferDecision(fileId, digest, value['accepted'] as bool);
    } catch (_) {
      return null;
    }
  }
}
