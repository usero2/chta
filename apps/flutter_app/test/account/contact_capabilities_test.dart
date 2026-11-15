import 'package:cht/account/account_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('signed card capability survives parsing and avatar enrichment', () {
    final contact = ContactView.fromJson({
      'identityId': 'did:cht:friend',
      'displayName': 'Friend',
      'fingerprint': '1234',
      'verified': true,
      'card': {'capabilities': ['relay-catalog-v1']},
    });
    expect(contact.withAvatar('avatar').capabilities, ['relay-catalog-v1']);
  });

  test('legacy card does not opt into peer control messages', () {
    final contact = ContactView.fromJson({
      'identityId': 'did:cht:friend',
      'displayName': 'Friend',
      'fingerprint': '1234',
      'verified': true,
    });
    expect(contact.capabilities, isEmpty);
  });
}
