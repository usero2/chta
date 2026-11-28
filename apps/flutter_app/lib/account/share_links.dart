import 'dart:convert';

const _contactTopic = 'urn:chta:contact:1';
const _groupTopic = 'urn:chta:group:1';
const _maxContactLinkLength = 24000;
final _did = RegExp(r'^did:cht:[a-f0-9]{64}$');
final _groupId = RegExp(r'^group:[a-f0-9]{64}$');
final _inviteId = RegExp(r'^[a-f0-9]{32}$');
final _base64 = RegExp(r'^[A-Za-z0-9_-]+$');

const _maxShareTokenLength = 32000;

String shareWebLink(String magnet) => Uri.https('chta.app', '/share/')
    .replace(
      fragment: base64Url.encode(utf8.encode(magnet)).replaceAll('=', ''),
    )
    .toString();

String? magnetFromShareToken(String token) {
  if (token.length > _maxShareTokenLength || !_base64.hasMatch(token)) {
    return null;
  }
  try {
    final value = utf8.decode(base64Url.decode(base64Url.normalize(token)));
    _magnet(value, _maxContactLinkLength);
    return value;
  } on FormatException {
    return null;
  }
}

String _unwrapShare(String value) {
  if (!value.startsWith('https://chta.app/share/')) return value;
  final link = Uri.tryParse(value);
  if (link == null ||
      link.authority != 'chta.app' ||
      link.path != '/share/' ||
      link.hasQuery) {
    throw const FormatException('Invalid chta share link.');
  }
  return magnetFromShareToken(link.fragment) ??
      (throw const FormatException('Invalid chta share link.'));
}

String contactMagnetLink(String signedCard) => Uri(
  scheme: 'magnet',
  queryParameters: {
    'xt': _contactTopic,
    'x.chta-card': base64Url
        .encode(utf8.encode(signedCard))
        .replaceAll('=', ''),
  },
).toString();

Uri _magnet(String input, int limit) {
  if (input.length > limit) throw const FormatException('Link is too large.');
  final uri = Uri.parse(input);
  if (uri.scheme != 'magnet' ||
      uri.hasAuthority ||
      uri.hasFragment ||
      uri.path.isNotEmpty ||
      uri.queryParametersAll.values.any((values) => values.length != 1)) {
    throw const FormatException('Invalid chta link.');
  }
  return uri;
}

bool isGroupMagnetLink(String input) {
  final value = _unwrapShare(input.trim());
  if (value.length > 512 || !value.toLowerCase().startsWith('magnet:')) {
    return false;
  }
  return _magnet(value, 512).queryParameters['xt'] == _groupTopic;
}

String contactCardFromShare(String input) {
  final value = _unwrapShare(input.trim());
  if (!value.toLowerCase().startsWith('magnet:')) return value;
  final params = _magnet(value, _maxContactLinkLength).queryParameters;
  final card = params['x.chta-card'];
  if (params['xt'] != _contactTopic ||
      card == null ||
      !_base64.hasMatch(card)) {
    throw const FormatException('Invalid contact link.');
  }
  return utf8.decode(base64Url.decode(base64Url.normalize(card)));
}

class GroupInviteLink {
  const GroupInviteLink({
    required this.invitationId,
    required this.groupId,
    required this.ownerId,
    required this.recipientId,
  });

  final String invitationId, groupId, ownerId, recipientId;

  Uri toUri() => Uri(
    scheme: 'magnet',
    queryParameters: {
      'xt': _groupTopic,
      'x.chta-invite': invitationId,
      'x.chta-group': groupId,
      'x.chta-owner': ownerId,
      'x.chta-recipient': recipientId,
    },
  );

  static GroupInviteLink parse(String input) {
    final params = _magnet(_unwrapShare(input.trim()), 512).queryParameters;
    final id = params['x.chta-invite'] ?? '';
    final group = params['x.chta-group'] ?? '';
    final owner = params['x.chta-owner'] ?? '';
    final recipient = params['x.chta-recipient'] ?? '';
    if (params['xt'] != _groupTopic ||
        !_inviteId.hasMatch(id) ||
        !_groupId.hasMatch(group) ||
        !_did.hasMatch(owner) ||
        !_did.hasMatch(recipient) ||
        owner == recipient) {
      throw const FormatException('Invalid group invitation link.');
    }
    return GroupInviteLink(
      invitationId: id,
      groupId: group,
      ownerId: owner,
      recipientId: recipient,
    );
  }
}
