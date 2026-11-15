import 'dart:convert';
import 'dart:io';

import 'profile_store.dart';

ProfileStore createPlatformProfileStore() => _NativeProfileStore();

class _NativeProfileStore implements ProfileStore {
  File get _file {
    final base =
        Platform.environment['APPDATA'] ??
        Platform.environment['HOME'] ??
        Directory.current.path;
    return File(
      '$base${Platform.pathSeparator}cht${Platform.pathSeparator}profile.json',
    );
  }

  @override
  Future<StoredProfile> load() async {
    if (!await _file.exists()) return const StoredProfile();
    final value = jsonDecode(await _file.readAsString());
    if (value is! Map<String, Object?>) return const StoredProfile();
    final avatar = value['avatar'] as String?;
    return StoredProfile(
      name: value['name'] as String? ?? '',
      avatar: avatar == null || avatar.isEmpty ? null : base64Decode(avatar),
    );
  }

  @override
  Future<void> save(StoredProfile profile) async {
    await _file.parent.create(recursive: true);
    final temporary = File('${_file.path}.tmp');
    await temporary.writeAsString(
      jsonEncode({
        'name': profile.name,
        'avatar': profile.avatar == null ? null : base64Encode(profile.avatar!),
      }),
      flush: true,
    );
    if (await _file.exists()) await _file.delete();
    await temporary.rename(_file.path);
  }
}
