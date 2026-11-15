import '../profile/profile_store.dart';
import 'account_models.dart';

class SavedIdentityView {
  const SavedIdentityView({
    required this.identityId,
    required this.displayName,
    this.avatarBase64 = '',
    this.lockedUntilMilliseconds = 0,
    this.requiresPin = true,
  });
  factory SavedIdentityView.fromJson(Map<String, Object?> value) =>
      SavedIdentityView(
        identityId: value['identityId']! as String,
        displayName: value['displayName']! as String,
        avatarBase64: value['avatar'] as String? ?? '',
        lockedUntilMilliseconds: value['lockedUntilMilliseconds'] as int? ?? 0,
        requiresPin: value['requiresPin'] as bool? ?? true,
      );
  final String identityId;
  final String displayName;
  final String avatarBase64;
  final int lockedUntilMilliseconds;
  final bool requiresPin;
}

abstract interface class DesktopIdentityBridge {
  bool get usesPlatformHistory;
  Future<String?> loadNativeHistory(String ownerId);
  Future<void> saveNativeHistory(String ownerId, String source);
  Future<List<SavedIdentityView>> savedIdentities();
  Future<IdentityView> rememberIdentity(
    String pin,
    String displayName,
    String avatar,
  );
  Future<IdentityView> unlockIdentity(String identityId, String pin);
  Future<void> lockIdentity();
  Future<StoredProfile> loadDesktopProfile();
  Future<void> saveDesktopProfile(StoredProfile profile);
}
