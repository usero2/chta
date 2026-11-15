import '../account/desktop_identity_bridge.dart';
import 'profile_store.dart';

class DesktopProfileStore implements ProfileStore {
  DesktopProfileStore(this.bridge);
  final DesktopIdentityBridge bridge;
  @override
  Future<StoredProfile> load() => bridge.loadDesktopProfile();
  @override
  Future<void> save(StoredProfile profile) =>
      bridge.saveDesktopProfile(profile);
}
