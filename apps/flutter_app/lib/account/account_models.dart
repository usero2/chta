class IdentityView {
  const IdentityView({
    required this.id,
    required this.rootPublicKey,
    required this.noiseStaticPublicKey,
    required this.derivationVersion,
  });

  factory IdentityView.fromJson(Map<String, Object?> json) => IdentityView(
    id: json['id']! as String,
    rootPublicKey: json['rootPublicKey']! as String,
    noiseStaticPublicKey: json['noiseStaticPublicKey']! as String,
    derivationVersion: json['derivationVersion']! as int,
  );

  final String id;
  final String rootPublicKey;
  final String noiseStaticPublicKey;
  final int derivationVersion;
}

class CreatedIdentityView {
  const CreatedIdentityView({required this.mnemonic, required this.identity});

  factory CreatedIdentityView.fromJson(Map<String, Object?> json) =>
      CreatedIdentityView(
        mnemonic: json['mnemonic']! as String,
        identity: IdentityView.fromJson(
          (json['identity']! as Map).cast<String, Object?>(),
        ),
      );

  final String mnemonic;
  final IdentityView identity;
}

class ContactView {
  const ContactView({
    required this.identityId,
    required this.displayName,
    required this.fingerprint,
    required this.verified,
    String? signedName,
    this.alias = '',
    this.avatarBase64 = '',
    this.relayUrls = const [],
    this.capabilities = const [],
    this.signedCard,
  }) : signedName = signedName ?? displayName;

  factory ContactView.fromJson(Map<String, Object?> json) => ContactView(
    identityId: json['identityId']! as String,
    displayName: json['displayName']! as String,
    fingerprint: json['fingerprint']! as String,
    verified: json['verified']! as bool,
    signedName: json['signedName'] as String?,
    alias: json['alias'] as String? ?? '',
    signedCard: (json['card'] as Map?)?.cast<String, Object?>(),
    relayUrls:
        (((json['card'] as Map?)?['relayUrls'] ?? json['relayUrls']) as List? ??
                const [])
            .cast<String>(),
    capabilities:
        (((json['card'] as Map?)?['capabilities'] ?? json['capabilities'])
                    as List? ??
                const [])
            .cast<String>(),
    avatarBase64:
        json['avatar'] as String? ??
        (json['card'] as Map?)?['avatar'] as String? ??
        '',
  );

  final String identityId;
  final String displayName;
  final String fingerprint;
  final bool verified;
  final String signedName;
  final String alias;
  final String avatarBase64;
  final List<String> relayUrls;
  final List<String> capabilities;
  final Map<String, Object?>? signedCard;

  ContactView withAvatar(String avatar) => ContactView(
    identityId: identityId,
    displayName: displayName,
    fingerprint: fingerprint,
    verified: verified,
    signedName: signedName,
    alias: alias,
    avatarBase64: avatar,
    relayUrls: relayUrls,
    capabilities: capabilities,
    signedCard: signedCard,
  );
}
