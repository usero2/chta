import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as image;

import 'profile_image_picker.dart';
import 'contact_avatar.dart';
import 'profile_store.dart';

class ProfileController extends ChangeNotifier {
  ProfileController(this.store);

  final ProfileStore store;
  String name = '';
  Uint8List? avatar;
  String contactAvatar = '';
  bool loading = true;
  Object? error;

  Future<void> load() async {
    try {
      final value = await store.load();
      name = value.name;
      avatar = value.avatar;
      contactAvatar = createContactAvatar(avatar);
      error = null;
    } catch (caught) {
      error = caught;
    }
    loading = false;
    notifyListeners();
  }

  Future<void> saveName(String value) async {
    final normalized = value.trim();
    if (normalized.isEmpty ||
        normalized.runes.length > maxProfileNameCharacters) {
      throw const FormatException('Name must contain 1 to 64 characters.');
    }
    name = normalized;
    await _persist();
  }

  Future<bool> chooseAvatar() async {
    final source = await pickProfileImage();
    if (source == null) return false;
    await setAvatarBytes(source);
    return true;
  }

  @visibleForTesting
  Future<void> setAvatarBytes(Uint8List source) async {
    if (source.length > 10 * 1024 * 1024) {
      throw const FormatException('The source image must be 10 MB or smaller.');
    }
    final decoded = image.decodeImage(source);
    if (decoded == null) throw const FormatException('Unsupported image file.');
    final side = decoded.width < decoded.height
        ? decoded.width
        : decoded.height;
    final square = image.copyCrop(
      decoded,
      x: (decoded.width - side) ~/ 2,
      y: (decoded.height - side) ~/ 2,
      width: side,
      height: side,
    );
    final resized = image.copyResize(
      square,
      width: profileAvatarPixels,
      height: profileAvatarPixels,
      interpolation: image.Interpolation.cubic,
    );
    final encoded = Uint8List.fromList(image.encodeJpg(resized, quality: 85));
    if (encoded.length > maxProfileAvatarBytes) {
      throw const FormatException('Processed avatar is larger than 256 KB.');
    }
    avatar = encoded;
    contactAvatar = createContactAvatar(avatar);
    await _persist();
  }

  Future<void> removeAvatar() async {
    avatar = null;
    contactAvatar = '';
    await _persist();
  }

  Future<void> _persist() async {
    await store.save(StoredProfile(name: name, avatar: avatar));
    error = null;
    notifyListeners();
  }
}
