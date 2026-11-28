import 'package:flutter/material.dart';

import '../../account/account_models.dart';
import '../../profile/profile_avatar.dart';
import 'contact_details_sheet.dart';

class MessageSenderAvatar extends StatelessWidget {
  const MessageSenderAvatar({
    required this.sender,
    required this.show,
    super.key,
  });

  final ContactView sender;
  final bool show;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 38,
    child: show
        ? IconButton(
            tooltip: 'View profile for ${sender.displayName}',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 34, height: 40),
            icon: ProfileAvatar(
              name: sender.displayName,
              avatarBase64: sender.avatarBase64,
              radius: 14,
            ),
            onPressed: () => showContactDetailsSheet(context, sender),
          )
        : null,
  );
}
