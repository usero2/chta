import 'dart:convert';

import 'package:cht/profile/contact_avatar.dart';
import 'package:cht/profile/profile_controller.dart';
import 'package:cht/profile/profile_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;

void main() {
  test('profile name is trimmed and persisted', () async {
    final store = _FakeProfileStore();
    final controller = ProfileController(store);

    await controller.load();
    await controller.saveName('  Alice  ');

    expect(controller.name, 'Alice');
    expect((await store.load()).name, 'Alice');
  });

  test('profile rejects empty and overlong names', () async {
    final controller = ProfileController(_FakeProfileStore());

    await expectLater(controller.saveName('   '), throwsFormatException);
    await expectLater(
      controller.saveName(List.filled(65, 'a').join()),
      throwsFormatException,
    );
  });

  test('avatar is cropped and resized to a compact square JPEG', () async {
    final controller = ProfileController(_FakeProfileStore());
    final source = image.Image(width: 600, height: 300);

    await controller.setAvatarBytes(image.encodePng(source));

    expect(controller.avatar, isNotNull);
    expect(controller.avatar!.length, lessThanOrEqualTo(maxProfileAvatarBytes));
    final decoded = image.decodeImage(controller.avatar!);
    expect(decoded?.width, profileAvatarPixels);
    expect(decoded?.height, profileAvatarPixels);
    final thumbnail = base64Decode(controller.contactAvatar);
    expect(thumbnail.length, lessThanOrEqualTo(maxContactAvatarBytes));
    expect(image.decodeJpg(thumbnail)?.width, lessThanOrEqualTo(64));
    final restored = ProfileController(controller.store);
    await restored.load();
    expect(restored.contactAvatar, controller.contactAvatar);
    await restored.removeAvatar();
    expect(restored.contactAvatar, isEmpty);
  });
}

class _FakeProfileStore implements ProfileStore {
  StoredProfile value = const StoredProfile();

  @override
  Future<StoredProfile> load() async => value;

  @override
  Future<void> save(StoredProfile profile) async => value = profile;
}
