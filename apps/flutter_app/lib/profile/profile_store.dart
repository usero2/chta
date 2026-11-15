import 'dart:typed_data';

import '../account/desktop_identity_bridge.dart';
import 'profile_store_desktop.dart';

import 'profile_store_stub.dart'
    if (dart.library.io) 'profile_store_native.dart'
    if (dart.library.js_interop) 'profile_store_web.dart';

const maxProfileNameCharacters = 64;
const profileAvatarPixels = 256;
const maxProfileAvatarBytes = 256 * 1024;

class StoredProfile {
  const StoredProfile({this.name = '', this.avatar});

  final String name;
  final Uint8List? avatar;
}

abstract interface class ProfileStore {
  Future<StoredProfile> load();
  Future<void> save(StoredProfile profile);
}

ProfileStore createProfileStore({DesktopIdentityBridge? identityBridge}) =>
    identityBridge == null
    ? createPlatformProfileStore()
    : DesktopProfileStore(identityBridge);
