import 'dart:convert';

import 'package:web/web.dart' as web;

import 'profile_store.dart';
import 'contact_avatar.dart';

const _profileKey = 'cht.profile';

ProfileStore createPlatformProfileStore() => _WebProfileStore();

class _WebProfileStore implements ProfileStore {
  @override
  Future<StoredProfile> load() async {
    final source = web.window.localStorage.getItem(_profileKey);
    if (source == null) {
      return StoredProfile(
        name: web.window.localStorage.getItem('cht.profile-name') ?? '',
      );
    }
    final value = jsonDecode(source);
    if (value is! Map<String, Object?>) return const StoredProfile();
    final avatar = value['avatar'] as String?;
    web.window.localStorage.setItem(
      'cht.contact-avatar',
      createContactAvatar(
        avatar == null || avatar.isEmpty ? null : base64Decode(avatar),
      ),
    );
    return StoredProfile(
      name: value['name'] as String? ?? '',
      avatar: avatar == null || avatar.isEmpty ? null : base64Decode(avatar),
    );
  }

  @override
  Future<void> save(StoredProfile profile) async {
    web.window.localStorage.setItem(
      'cht.contact-avatar',
      createContactAvatar(profile.avatar),
    );
    web.window.localStorage.setItem(
      _profileKey,
      jsonEncode({
        'name': profile.name,
        'avatar': profile.avatar == null ? null : base64Encode(profile.avatar!),
      }),
    );
    web.window.localStorage.setItem('cht.profile-name', profile.name);
  }
}
