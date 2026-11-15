import 'profile_store.dart';

ProfileStore createPlatformProfileStore() => _MemoryProfileStore();

class _MemoryProfileStore implements ProfileStore {
  StoredProfile profile = const StoredProfile();

  @override
  Future<StoredProfile> load() async => profile;

  @override
  Future<void> save(StoredProfile value) async => profile = value;
}
