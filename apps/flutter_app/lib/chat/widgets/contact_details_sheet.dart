import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../account/account_models.dart';
import '../../profile/profile_avatar.dart';

Future<void> showContactDetailsSheet(
  BuildContext context,
  ContactView contact,
) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  builder: (context) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Contact details',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              ProfileAvatar(
                name: contact.displayName,
                avatarBase64: contact.avatarBase64,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      contact.signedName,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    Text(
                      'Local alias: ${contact.alias.isEmpty ? 'None' : contact.alias}',
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          _CopyDetail(label: 'Fingerprint', value: contact.fingerprint),
          const SizedBox(height: 12),
          _CopyDetail(label: 'DID', value: contact.identityId),
        ],
      ),
    ),
  ),
);

class _CopyDetail extends StatelessWidget {
  const _CopyDetail({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 4),
            SelectableText(value),
          ],
        ),
      ),
      IconButton(
        tooltip: 'Copy $label',
        onPressed: () => Clipboard.setData(ClipboardData(text: value)),
        icon: const Icon(Icons.copy_outlined),
      ),
    ],
  );
}
