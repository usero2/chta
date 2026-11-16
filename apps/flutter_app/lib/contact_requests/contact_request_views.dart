import 'package:flutter/material.dart';

import '../account/account_models.dart';
import '../profile/profile_avatar.dart';
import 'contact_request_controller.dart';

class FriendRequestsSection extends StatelessWidget {
  const FriendRequestsSection({
    required this.controller,
    required this.onAccepted,
    super.key,
  });
  final ContactRequestController controller;
  final ValueChanged<ContactView> onAccepted;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final pending = controller.incoming;
      if (pending.isEmpty) return const SizedBox.shrink();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              'Friend requests (${pending.length})',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
          ),
          for (final request in pending)
            Card(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    ProfileAvatar(
                      name: request.contact.displayName,
                      avatarBase64: request.contact.avatarBase64,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        request.contact.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    TextButton(
                      onPressed: () async {
                        final contact = await reviewContactRequest(
                          context,
                          controller,
                          request,
                        );
                        if (contact != null && context.mounted) {
                          onAccepted(contact);
                        }
                      },
                      child: const Text('Review'),
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 12),
        ],
      );
    },
  );
}

Future<ContactView?> reviewContactRequest(
  BuildContext context,
  ContactRequestController controller,
  ContactRequest request,
) async {
  final alias = TextEditingController();
  var working = false;
  String? error;
  final navigator = Navigator.of(context, rootNavigator: true);
  final route = DialogRoute<ContactView>(
    context: context,
    themes: InheritedTheme.capture(from: context, to: navigator.context),
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        Future<void> decide(bool accept) async {
          if (working) return;
          setState(() {
            working = true;
            error = null;
          });
          try {
            final contact = accept
                ? await controller.accept(request.id, alias: alias.text)
                : null;
            if (!accept) await controller.decline(request.id);
            if (context.mounted) Navigator.pop(context, contact);
          } catch (_) {
            if (context.mounted) {
              setState(() {
                working = false;
                error = 'Could not save your choice. Retry.';
              });
            }
          }
        }

        return AlertDialog(
          title: const Text('Friend request'),
          scrollable: true,
          content: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    ProfileAvatar(
                      name: request.contact.displayName,
                      avatarBase64: request.contact.avatarBase64,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        request.contact.displayName,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                const Text('Fingerprint'),
                SelectableText(request.contact.fingerprint),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('request-alias-input'),
                  controller: alias,
                  enabled: !working,
                  maxLength: 64,
                  decoration: const InputDecoration(
                    labelText: 'Alias (optional)',
                  ),
                ),
                if (error != null)
                  Text(error!, style: const TextStyle(color: Colors.redAccent)),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: working ? null : () => Navigator.pop(context),
              child: const Text('Close'),
            ),
            TextButton(
              onPressed: working ? null : () => decide(false),
              child: const Text('Decline'),
            ),
            FilledButton(
              onPressed: working ? null : () => decide(true),
              child: Text(working ? 'Saving…' : 'Accept'),
            ),
          ],
        );
      },
    ),
  );
  final result = await navigator.push(route);
  await route.completed;
  alias.dispose();
  return result;
}
