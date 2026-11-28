import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../account/account_models.dart';
import '../account/contact_qr_files.dart';
import '../account/share_links.dart';
import '../profile/profile_avatar.dart';
import 'group_controller.dart';
import 'group_models.dart';

Future<(String, List<String>)?> showCreateGroupDialog(
  BuildContext context,
  List<ContactView> contacts,
) => showDialog<(String, List<String>)>(
  context: context,
  builder: (context) => _CreateGroupDialog(contacts: contacts),
);

class _CreateGroupDialog extends StatefulWidget {
  const _CreateGroupDialog({required this.contacts});
  final List<ContactView> contacts;

  @override
  State<_CreateGroupDialog> createState() => _CreateGroupDialogState();
}

class _CreateGroupDialogState extends State<_CreateGroupDialog> {
  final _name = TextEditingController();
  final _selected = <String>{};

  List<ContactView> get _verified => widget.contacts
      .where((contact) => contact.verified)
      .toList(growable: false);

  bool get _canCreate =>
      _name.text.trim().isNotEmpty &&
      _name.text.trim().characters.length <= 64 &&
      _selected.isNotEmpty;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final maxHeight = media.size.height - media.viewInsets.bottom - 32;
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: maxHeight > 160 ? maxHeight : 160,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('New group', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 16),
              TextField(
                key: const Key('new-group-name'),
                controller: _name,
                maxLength: 64,
                maxLengthEnforcement: MaxLengthEnforcement.enforced,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Group name',
                  border: OutlineInputBorder(),
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 8),
              Text(
                'Choose friends',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              Text('${_selected.length}/15 selected'),
              const SizedBox(height: 8),
              if (_verified.isEmpty)
                const Text('No verified friends available.')
              else
                for (final contact in _verified)
                  CheckboxListTile(
                    key: Key('create-group-contact:${contact.identityId}'),
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      contact.alias.isEmpty
                          ? contact.displayName
                          : contact.alias,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    secondary: ProfileAvatar(
                      name: contact.displayName,
                      avatarBase64: contact.avatarBase64,
                      radius: 18,
                    ),
                    value: _selected.contains(contact.identityId),
                    onChanged:
                        !_selected.contains(contact.identityId) &&
                            _selected.length >= 15
                        ? null
                        : (selected) => setState(() {
                            if (selected == true) {
                              _selected.add(contact.identityId);
                            } else {
                              _selected.remove(contact.identityId);
                            }
                          }),
                  ),
              const SizedBox(height: 8),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                  ElevatedButton(
                    onPressed: _canCreate
                        ? () {
                            final ids = _verified
                                .where((c) => _selected.contains(c.identityId))
                                .map((c) => c.identityId)
                                .toList(growable: false);
                            Navigator.pop(context, (_name.text.trim(), ids));
                          }
                        : null,
                    child: const Text('Create'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> showGroupDetails(
  BuildContext context, {
  required GroupView group,
  required String ownId,
  required List<ContactView> contacts,
  required Future<void> Function(String) onInvite,
  Future<GroupInviteLink> Function(String)? onShareInvite,
  required Future<void> Function(String) onRemove,
  required Future<void> Function() onLeave,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (context) => _GroupDetailsSheet(
    group: group,
    ownId: ownId,
    contacts: contacts,
    onInvite: onInvite,
    onShareInvite: onShareInvite,
    onRemove: onRemove,
    onLeave: onLeave,
  ),
);

class _GroupDetailsSheet extends StatefulWidget {
  const _GroupDetailsSheet({
    required this.group,
    required this.ownId,
    required this.contacts,
    required this.onInvite,
    this.onShareInvite,
    required this.onRemove,
    required this.onLeave,
  });

  final GroupView group;
  final String ownId;
  final List<ContactView> contacts;
  final Future<void> Function(String) onInvite, onRemove;
  final Future<GroupInviteLink> Function(String)? onShareInvite;
  final Future<void> Function() onLeave;

  @override
  State<_GroupDetailsSheet> createState() => _GroupDetailsSheetState();
}

class _GroupDetailsSheetState extends State<_GroupDetailsSheet> {
  final _busy = <String>{};
  final _invited = <String>{};
  final _removed = <String>{};

  bool get _isOwner => widget.ownId == widget.group.ownerId;

  ContactView? _contact(String id) {
    for (final contact in widget.contacts) {
      if (contact.identityId == id) return contact;
    }
    return null;
  }

  Future<void> _run(
    String key,
    Future<void> Function() action, {
    VoidCallback? onSuccess,
  }) async {
    if (_busy.contains(key)) return;
    setState(() => _busy.add(key));
    try {
      await action();
      if (mounted) onSuccess?.call();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not complete that action. Try again.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy.remove(key));
    }
  }

  Future<bool> _confirm({
    required String title,
    required String message,
    required String action,
  }) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(action),
            ),
          ],
        ),
      ) ??
      false;

  @override
  Widget build(BuildContext context) {
    final group = widget.group;
    final maxHeight = MediaQuery.sizeOf(context).height * 0.86;
    final invitees = _isOwner && !group.closed
        ? widget.contacts.where(
            (contact) =>
                contact.verified &&
                !group.contains(contact.identityId) &&
                (!_invited.contains(contact.identityId) ||
                    widget.onShareInvite != null),
          )
        : const <ContactView>[];
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(group.name, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text('${group.members.length - _removed.length} members'),
            const SizedBox(height: 16),
            for (final member in group.members.where(
              (m) => !_removed.contains(m.identityId),
            ))
              _MemberRow(
                member: member,
                contact: _contact(member.identityId),
                creator: member.identityId == group.ownerId,
                remove:
                    _isOwner &&
                    member.identityId != group.ownerId &&
                    !group.closed,
                busy: _busy.contains('remove:${member.identityId}'),
                onRemove: () async {
                  final confirmed = await _confirm(
                    title: 'Remove ${member.displayName}?',
                    message: 'Remove this member from the group?',
                    action: 'Remove member',
                  );
                  if (!confirmed || !mounted) return;
                  await _run(
                    'remove:${member.identityId}',
                    () => widget.onRemove(member.identityId),
                    onSuccess: () =>
                        setState(() => _removed.add(member.identityId)),
                  );
                },
              ),
            if (invitees.isNotEmpty) ...[
              const Divider(height: 24),
              Text(
                'Invite friends',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              for (final contact in invitees)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: ProfileAvatar(
                    name: contact.displayName,
                    avatarBase64: contact.avatarBase64,
                    radius: 18,
                  ),
                  title: Text(
                    contact.alias.isEmpty ? contact.displayName : contact.alias,
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (widget.onShareInvite != null)
                        IconButton(
                          tooltip: 'Share invitation',
                          icon: const Icon(Icons.qr_code_2),
                          onPressed:
                              _busy.contains('share:${contact.identityId}')
                              ? null
                              : () => _run(
                                  'share:${contact.identityId}',
                                  () async {
                                    final link = await widget.onShareInvite!(
                                      contact.identityId,
                                    );
                                    if (context.mounted) {
                                      await _showInviteToShare(
                                        context,
                                        contact.displayName,
                                        link,
                                      );
                                    }
                                  },
                                ),
                        ),
                      if (!_invited.contains(contact.identityId))
                        TextButton(
                          key: Key('group-invite:${contact.identityId}'),
                          onPressed:
                              _busy.contains('invite:${contact.identityId}')
                              ? null
                              : () => _run(
                                  'invite:${contact.identityId}',
                                  () => widget.onInvite(contact.identityId),
                                  onSuccess: () => setState(
                                    () => _invited.add(contact.identityId),
                                  ),
                                ),
                          child: Text(
                            _busy.contains('invite:${contact.identityId}')
                                ? 'Inviting…'
                                : 'Invite',
                          ),
                        ),
                    ],
                  ),
                ),
            ],
            const Divider(height: 24),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: _busy.contains('leave')
                    ? null
                    : () async {
                        final owner = _isOwner;
                        final confirmed = await _confirm(
                          title: owner
                              ? 'Close this group for everyone?'
                              : 'Leave this group?',
                          message: owner
                              ? 'Closing this group ends it for all members.'
                              : 'You will leave this group and stop receiving its messages.',
                          action: owner ? 'Close group' : 'Leave group',
                        );
                        if (!confirmed || !mounted) return;
                        await _run(
                          'leave',
                          widget.onLeave,
                          onSuccess: () => Navigator.pop(context),
                        );
                      },
                child: Text(_isOwner ? 'Close group' : 'Leave group'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MemberRow extends StatelessWidget {
  const _MemberRow({
    required this.member,
    required this.contact,
    required this.creator,
    required this.remove,
    required this.busy,
    required this.onRemove,
  });

  final GroupMember member;
  final ContactView? contact;
  final bool creator, remove, busy;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final name = contact == null
        ? member.displayName
        : contact!.alias.isEmpty
        ? contact!.displayName
        : contact!.alias;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: ProfileAvatar(
        name: name,
        avatarBase64: contact?.avatarBase64 ?? '',
        radius: 20,
      ),
      title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: creator ? const Text('Creator') : null,
      trailing: remove
          ? TextButton(
              key: Key('group-remove:${member.identityId}'),
              onPressed: busy ? null : onRemove,
              child: Text(busy ? 'Removing…' : 'Remove'),
            )
          : null,
    );
  }
}

Future<bool> confirmDeleteGroupChat(BuildContext context) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete group chat history?'),
        content: const Text(
          'This removes the chat history from this device. Your group membership will remain.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete history'),
          ),
        ],
      ),
    ) ??
    false;

Future<void> _showInviteToShare(
  BuildContext context,
  String friend,
  GroupInviteLink invite,
) async {
  final magnet = invite.toUri().toString();
  final link = shareWebLink(magnet);
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Invite $friend'),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ContactQrView(card: magnet, size: 224),
          const SizedBox(height: 12),
          Text('Only $friend can use this invitation.'),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Done'),
        ),
        FilledButton.icon(
          icon: const Icon(Icons.copy_outlined),
          label: const Text('Copy link'),
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: link));
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Invitation link copied.')),
              );
            }
          },
        ),
      ],
    ),
  );
}

Future<bool> showSharedGroupInvitation(
  BuildContext context, {
  required GroupController controller,
  required GroupInviteLink link,
  required String ownerName,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) {
        var joining = false;
        String? error;
        return StatefulBuilder(
          builder: (context, setDialogState) => ListenableBuilder(
            listenable: controller,
            builder: (context, _) {
              final invite = controller.invitationForLink(link);
              final joined = controller.canSend(link.groupId);
              return AlertDialog(
                title: Text(invite?.name ?? 'Group invitation'),
                content: Text(
                  error ??
                      (joined
                          ? 'You are already a member of this group.'
                          : invite == null
                          ? 'Waiting for $ownerName to come online and send the invitation.'
                          : 'Invited by $ownerName'),
                ),
                actions: [
                  TextButton(
                    onPressed: joining
                        ? null
                        : () => Navigator.pop(context, false),
                    child: const Text('Close'),
                  ),
                  if (invite != null || joined)
                    FilledButton(
                      onPressed: joining
                          ? null
                          : () async {
                              if (joined) {
                                Navigator.pop(context, true);
                                return;
                              }
                              setDialogState(() {
                                joining = true;
                                error = null;
                              });
                              try {
                                await controller.acceptInvitation(invite!.id);
                                if (context.mounted) {
                                  Navigator.pop(context, true);
                                }
                              } catch (_) {
                                if (context.mounted) {
                                  setDialogState(() {
                                    joining = false;
                                    error =
                                        'Could not join the group. Try again.';
                                  });
                                }
                              }
                            },
                      child: Text(joined ? 'Open group' : 'Join group'),
                    ),
                ],
              );
            },
          ),
        );
      },
    ) ??
    false;

Future<void> showGroupInvitations(
  BuildContext context, {
  required List<GroupInvitation> invitations,
  required List<ContactView> contacts,
  required Future<void> Function(String) onAccept,
  required Future<void> Function(String) onDecline,
}) => showDialog<void>(
  context: context,
  builder: (context) => _GroupInvitationsDialog(
    invitations: invitations,
    contacts: contacts,
    onAccept: onAccept,
    onDecline: onDecline,
  ),
);

class _GroupInvitationsDialog extends StatefulWidget {
  const _GroupInvitationsDialog({
    required this.invitations,
    required this.contacts,
    required this.onAccept,
    required this.onDecline,
  });
  final List<GroupInvitation> invitations;
  final List<ContactView> contacts;
  final Future<void> Function(String) onAccept, onDecline;

  @override
  State<_GroupInvitationsDialog> createState() =>
      _GroupInvitationsDialogState();
}

class _GroupInvitationsDialogState extends State<_GroupInvitationsDialog> {
  final _remaining = <String>{};
  final _busy = <String>{};

  @override
  void initState() {
    super.initState();
    _remaining.addAll(widget.invitations.map((i) => i.id));
  }

  String _ownerName(String id) {
    for (final contact in widget.contacts) {
      if (contact.identityId == id) {
        return contact.alias.isEmpty ? contact.displayName : contact.alias;
      }
    }
    return 'Owner ${id.length > 16 ? id.substring(8, 16) : id}';
  }

  Future<void> _act(GroupInvitation invitation, bool accept) async {
    if (!_busy.add(invitation.id)) return;
    setState(() {});
    try {
      if (accept) {
        await widget.onAccept(invitation.id);
      } else {
        await widget.onDecline(invitation.id);
      }
      if (mounted) {
        setState(() => _remaining.remove(invitation.id));
        if (_remaining.isEmpty) Navigator.pop(context);
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not update this invitation. Try again.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy.remove(invitation.id));
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Group invitations'),
    content: ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: 520,
        maxHeight: MediaQuery.sizeOf(context).height * 0.65,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_remaining.isEmpty) const Text('No group invitations.'),
            for (final invitation in widget.invitations.where(
              (i) => _remaining.contains(i.id),
            ))
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      invitation.name,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    Text('From ${_ownerName(invitation.ownerId)}'),
                    Wrap(
                      alignment: WrapAlignment.end,
                      spacing: 8,
                      children: [
                        TextButton(
                          key: Key('group-invitation-decline:${invitation.id}'),
                          onPressed: _busy.contains(invitation.id)
                              ? null
                              : () => _act(invitation, false),
                          child: const Text('Decline'),
                        ),
                        ElevatedButton(
                          key: Key('group-invitation-accept:${invitation.id}'),
                          onPressed: _busy.contains(invitation.id)
                              ? null
                              : () => _act(invitation, true),
                          child: Text(
                            _busy.contains(invitation.id)
                                ? 'Working…'
                                : 'Accept',
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Close'),
      ),
    ],
  );
}
