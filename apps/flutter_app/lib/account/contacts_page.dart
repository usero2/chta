import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../qr/qr_scanner_page.dart';

import 'account_bridge.dart';
import 'account_models.dart';
import 'routed_contact_bridge.dart';
import 'share_links.dart';
import 'share_link_inbox.dart';
import '../relay/relay_network.dart';
import 'contact_qr_files.dart';
import '../profile/profile_controller.dart';
import '../profile/profile_avatar.dart';
import '../chat/peer_history.dart';
import '../contact_requests/contact_request_controller.dart';
import '../contact_requests/contact_request_views.dart';

class ContactsPage extends StatefulWidget {
  const ContactsPage({
    required this.bridge,
    required this.identity,
    required this.onChat,
    required this.profileController,
    this.refreshToken = 0,
    this.peerHistory,
    this.readQrImage,
    this.relayNetwork,
    this.requests,
    this.onGroupInvite,
    this.onOpenSharedLink,
    this.canOpenGroupLinks = true,
    super.key,
  });

  final AccountBridge bridge;
  final IdentityView identity;
  final ValueChanged<ContactView> onChat;
  final ProfileController profileController;
  final int refreshToken;
  final PeerHistory? peerHistory;
  final Future<String?> Function()? readQrImage;
  final RelayNetwork? relayNetwork;
  final ContactRequestController? requests;
  final Future<void> Function(GroupInviteLink)? onGroupInvite;
  final VoidCallback? onOpenSharedLink;
  final bool canOpenGroupLinks;

  @override
  State<ContactsPage> createState() => _ContactsPageState();
}

class _ContactsPageState extends State<ContactsPage> {
  late Future<String> _card;
  late Future<List<ContactView>> _friends;
  late Future<(String, List<ContactView>)> data;
  late String _sharedRoutes;
  int? _avatarRevision;

  String get _relaySnapshot =>
      widget.relayNetwork?.contactRelayUrls.join('|') ?? '';

  @override
  void initState() {
    super.initState();
    _sharedRoutes = _relaySnapshot;
    _avatarRevision = widget.peerHistory?.avatarRevision;
    _card = _ownCard();
    _friends = widget.bridge.contacts();
    data = (_card, _friends).wait;
    widget.profileController.addListener(_refreshCard);
    widget.peerHistory?.addListener(_historyChanged);
    widget.relayNetwork?.addListener(_relayChanged);
    pendingShareLink.addListener(_openPendingShare);
    _openPendingShare();
  }

  void _historyChanged() {
    final revision = widget.peerHistory?.avatarRevision;
    if (!mounted || revision == _avatarRevision) return;
    setState(() => _avatarRevision = revision);
  }

  void _openPendingShare() {
    if (pendingShareLink.value == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || pendingShareLink.value == null) return;
      final link = pendingShareLink.value!;
      if (!widget.canOpenGroupLinks && isGroupMagnetLink(link)) return;
      pendingShareLink.value = null;
      widget.onOpenSharedLink?.call();
      unawaited(_addContact(initialCard: link));
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void dispose() {
    pendingShareLink.removeListener(_openPendingShare);
    widget.profileController.removeListener(_refreshCard);
    widget.peerHistory?.removeListener(_historyChanged);
    widget.relayNetwork?.removeListener(_relayChanged);
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant ContactsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.canOpenGroupLinks && !oldWidget.canOpenGroupLinks) {
      _openPendingShare();
    }
    if (oldWidget.profileController != widget.profileController) {
      oldWidget.profileController.removeListener(_refreshCard);
      widget.profileController.addListener(_refreshCard);
      _refreshCard();
    }
    if (oldWidget.peerHistory != widget.peerHistory) {
      oldWidget.peerHistory?.removeListener(_historyChanged);
      widget.peerHistory?.addListener(_historyChanged);
      _avatarRevision = widget.peerHistory?.avatarRevision;
    }
    if (oldWidget.refreshToken != widget.refreshToken) _refreshFriends();
    if (oldWidget.bridge != widget.bridge ||
        oldWidget.identity.id != widget.identity.id) {
      _refreshCard();
      _refreshFriends();
    }
    if (oldWidget.relayNetwork != widget.relayNetwork) {
      oldWidget.relayNetwork?.removeListener(_relayChanged);
      widget.relayNetwork?.addListener(_relayChanged);
      _relayChanged();
    }
  }

  void _relayChanged() {
    final routes = _relaySnapshot;
    if (_sharedRoutes != routes) {
      _sharedRoutes = routes;
      if (mounted) _refreshCard();
    }
  }

  Future<String> _ownCard() {
    final bridge = widget.bridge;
    if (bridge is RoutedContactBridge) {
      return (bridge as RoutedContactBridge).contactCardWithRelays(
        displayName: widget.profileController.name,
        avatar: widget.profileController.contactAvatar,
        relayUrls: widget.relayNetwork?.contactRelayUrls ?? const [],
      );
    }
    return bridge.contactCard(
      displayName: widget.profileController.name,
      avatar: widget.profileController.contactAvatar,
    );
  }

  void _refreshCard() => setState(() {
    _card = _ownCard();
    data = (_card, _friends).wait;
  });

  void _refreshFriends([List<ContactView>? saved]) => setState(() {
    _friends = saved == null ? widget.bridge.contacts() : Future.value(saved);
    data = (_card, _friends).wait;
  });

  // Navigator.pop resolves before the closing animation removes the fields.
  // Keep their controllers alive until the route has left the overlay.
  Future<T?> _dialog<T>(WidgetBuilder builder) async {
    final navigator = Navigator.of(context, rootNavigator: true);
    final route = DialogRoute<T>(
      context: context,
      themes: InheritedTheme.capture(from: context, to: navigator.context),
      builder: builder,
    );
    final result = await navigator.push(route);
    await route.completed;
    return result;
  }

  Future<void> _editAlias(ContactView contact) async {
    final controller = TextEditingController(text: contact.alias);
    final alias = await _dialog<String>(
      (context) => AlertDialog(
        scrollable: true,
        title: const Text('Edit alias'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Signed name: ${contact.signedName}'),
              const SizedBox(height: 12),
              TextField(
                key: const Key('contact-alias-input'),
                controller: controller,
                autofocus: true,
                maxLength: 64,
                decoration: const InputDecoration(
                  labelText: 'Alias',
                  hintText: 'Blank uses the original name',
                ),
                onSubmitted: (value) => Navigator.pop(context, value),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          if (contact.alias.isNotEmpty)
            TextButton(
              onPressed: () => Navigator.pop(context, ''),
              child: const Text('Use signed name'),
            ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (alias == null) return;
    try {
      final contacts = await widget.bridge.setContactAlias(
        contact.identityId,
        alias,
      );
      if (mounted) _refreshFriends(contacts);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Unable to save alias: $error')));
      }
    }
  }

  Future<void> _addContact({String initialCard = ''}) async {
    final card = TextEditingController(text: initialCard);
    TextEditingController? alias;
    if (initialCard.isEmpty) {
      final accepted = await _dialog<bool>(
        (context) => AlertDialog(
          scrollable: true,
          title: const Text('Paste card or link'),
          content: SizedBox(
            width: 560,
            child: TextField(
              key: const Key('friend-card-input'),
              controller: card,
              minLines: 5,
              maxLines: 10,
              decoration: InputDecoration(
                labelText: 'Contact card or link',
                suffixIcon: IconButton(
                  tooltip: 'Paste from clipboard',
                  icon: const Icon(Icons.content_paste),
                  onPressed: () async {
                    final clipboard = await Clipboard.getData(
                      Clipboard.kTextPlain,
                    );
                    final value = clipboard?.text;
                    if (context.mounted && value != null) card.text = value;
                  },
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Check card'),
            ),
          ],
        ),
      );
      if (accepted != true) {
        card.dispose();
        return;
      }
    }

    try {
      final value = card.text.trim();
      if (isGroupMagnetLink(value)) {
        final open = widget.onGroupInvite;
        if (open == null) {
          throw const FormatException('Group invitations unavailable.');
        }
        await open(GroupInviteLink.parse(value));
        return;
      }
      final signedCard = contactCardFromShare(value);
      final inspected = await widget.bridge.inspectContactCard(signedCard);
      if (!mounted) return;
      alias = TextEditingController();
      var fingerprintChecked = false;
      final accepted = await _dialog<bool>(
        (context) => StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            scrollable: true,
            title: Text('Add ${inspected.displayName}'),
            content: SizedBox(
              width: 560,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Signed name'),
                  SelectableText(inspected.displayName),
                  const SizedBox(height: 12),
                  const Text('Fingerprint'),
                  SelectableText(inspected.fingerprint),
                  const SizedBox(height: 12),
                  Text(
                    inspected.relayUrls.isEmpty
                        ? 'No relay included.'
                        : 'Relay included. Connects after verification.',
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const Key('friend-alias-input'),
                    controller: alias,
                    maxLength: 64,
                    decoration: const InputDecoration(
                      labelText: 'Alias (optional)',
                      hintText: 'Only you see this name',
                    ),
                  ),
                  if (widget.requests == null)
                    CheckboxListTile(
                      value: fingerprintChecked,
                      contentPadding: EdgeInsets.zero,
                      onChanged: (value) => setDialogState(
                        () => fingerprintChecked = value ?? false,
                      ),
                      title: const Text('Fingerprint matches'),
                      subtitle: const Text(
                        'Compare with your friend in person or by call.',
                      ),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                key: const Key('confirm-add-friend'),
                onPressed: () => Navigator.pop(context, true),
                child: Text(
                  widget.requests == null && fingerprintChecked
                      ? 'Add friend & chat'
                      : 'Add friend',
                ),
              ),
            ],
          ),
        ),
      );
      if (accepted == true) {
        await widget.bridge.addContact(signedCard, alias.text);
        if (fingerprintChecked || widget.requests != null) {
          await widget.bridge.markContactVerified(inspected.identityId);
        }
        if (widget.requests != null) {
          await widget.requests!.request(inspected.identityId);
        }
        if (!mounted) return;
        final saved = await widget.bridge.contacts();
        if (!mounted) return;
        _refreshFriends(saved);
        if (fingerprintChecked || widget.requests != null) {
          final friend = saved
              .where((c) => c.identityId == inspected.identityId)
              .firstOrNull;
          if (friend != null && mounted) widget.onChat(friend);
        }
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              error is FormatException
                  ? error.message
                  : 'Unable to open card or link.',
            ),
          ),
        );
      }
    } finally {
      alias?.dispose();
      card.dispose();
    }
  }

  Future<void> _scan() async {
    final value = await scanQr(
      context,
      title: 'Scan QR',
      fallbackText: 'Import a QR image or paste a link.',
    );
    if (value != null && mounted) {
      await _addContact(initialCard: value);
    }
  }

  Future<void> _importQrImage() async {
    try {
      final value = await (widget.readQrImage ?? readContactQrImage)();
      if (value != null && mounted) await _addContact(initialCard: value);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Unable to read QR image: $error')),
        );
      }
    }
  }

  Future<void> _saveQrImage(String card) async {
    try {
      await saveContactQrImage(card);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not save the QR image.')),
        );
      }
    }
  }

  Future<void> _copyShare(String text, String confirmation) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(confirmation)));
  }

  Widget _shareCard(String card) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          ProfileAvatar(
            key: const Key('my-contact-avatar'),
            name: widget.profileController.name,
            bytes: widget.profileController.avatar,
            radius: 22,
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              widget.profileController.name.isEmpty
                  ? 'Your profile'
                  : widget.profileController.name,
              key: const Key('my-contact-name'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
        ],
      ),
      const SizedBox(height: 12),
      Center(
        child: ContactQrView(
          key: const Key('my-contact-qr'),
          card: card,
          size: 260,
        ),
      ),
      const SizedBox(height: 12),
      Wrap(
        spacing: 8,
        runSpacing: 6,
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          FilledButton.icon(
            key: const Key('copy-contact-link'),
            onPressed: () => _copyShare(
              shareWebLink(contactMagnetLink(card)),
              'Contact link copied.',
            ),
            icon: const Icon(Icons.link),
            label: const Text('Copy link'),
          ),
          if (supportsContactQrImageExport)
            OutlinedButton.icon(
              key: const Key('save-my-qr-image'),
              onPressed: () => _saveQrImage(card),
              icon: const Icon(Icons.download_outlined),
              label: const Text('Save QR'),
            ),
          IconButton(
            tooltip: 'Copy contact card',
            onPressed: () => _copyShare(card, 'Card copied.'),
            icon: const Icon(Icons.copy_outlined),
          ),
        ],
      ),
      ExpansionTile(
        title: const Text('Contact details'),
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 8),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: SelectableText(widget.identity.id),
          ),
          Text(_sharedRoutes.isEmpty ? 'No relay included' : 'Relay included'),
        ],
      ),
    ],
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Contacts'),
      actions: [
        IconButton(
          key: const Key('scan-friend-qr'),
          onPressed: _scan,
          tooltip: 'Scan QR',
          icon: const Icon(Icons.qr_code_scanner),
        ),
        if (supportsContactQrImageImport || widget.readQrImage != null)
          IconButton(
            key: const Key('import-friend-qr-image'),
            onPressed: _importQrImage,
            tooltip: 'Import QR image',
            icon: const Icon(Icons.image_search_outlined),
          ),
        IconButton(
          key: const Key('paste-friend-card'),
          onPressed: _addContact,
          tooltip: 'Paste card or link',
          icon: const Icon(Icons.person_add),
        ),
      ],
    ),
    body: FutureBuilder<(String, List<ContactView>)>(
      future: data,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: Text('Unable to load contacts: ${snapshot.error}'),
          );
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final (card, contacts) = snapshot.data!;
        return ListView.builder(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          itemCount: contacts.length + 1,
          itemBuilder: (context, index) {
            if (index == 0) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 480),
                      child: _shareCard(card),
                    ),
                  ),
                  const Divider(height: 24),
                  if (widget.requests case final requests?)
                    FriendRequestsSection(
                      controller: requests,
                      onAccepted: widget.onChat,
                    ),
                  Text(
                    'Friends',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  if (contacts.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 24),
                      child: Text('No friends yet.'),
                    ),
                ],
              );
            }
            return _friendCard(contacts[index - 1]);
          },
        );
      },
    ),
  );

  Widget _friendCard(ContactView contact) => Card(
    key: ValueKey(contact.identityId),
    child: Padding(
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            key: Key('friend-header-${contact.identityId}'),
            children: [
              ProfileAvatar(
                key: Key('friend-avatar-${contact.identityId}'),
                radius: 18,
                name: contact.displayName,
                avatarBase64:
                    (widget.peerHistory?.withCachedAvatar(contact) ?? contact)
                        .avatarBase64,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Tooltip(
                  message: contact.displayName,
                  child: Text(
                    contact.displayName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              IconButtonTheme(
                data: IconButtonThemeData(
                  style: IconButton.styleFrom(
                    minimumSize: const Size(44, 44),
                    maximumSize: const Size(44, 44),
                    padding: EdgeInsets.zero,
                    iconSize: 20,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      key: Key('edit-alias-${contact.identityId}'),
                      tooltip: 'Set alias for ${contact.signedName}',
                      onPressed: () => _editAlias(contact),
                      icon: const Icon(Icons.edit_outlined),
                    ),
                    IconButton(
                      key: Key('chat-contact-${contact.identityId}'),
                      tooltip: contact.verified
                          ? 'Chat with ${contact.displayName}'
                          : 'Verify fingerprint before chatting',
                      onPressed: contact.verified
                          ? () => widget.onChat(contact)
                          : null,
                      icon: const Icon(Icons.chat_bubble_outline),
                    ),
                    if (contact.verified)
                      IconButton(
                        tooltip: 'Remove',
                        onPressed: () async {
                          await widget.bridge.removeContact(contact.identityId);
                          _refreshFriends();
                        },
                        icon: const Icon(Icons.delete_outline),
                      )
                    else
                      SizedBox.square(
                        dimension: 44,
                        child: PopupMenuButton<String>(
                          tooltip: 'More friend actions',
                          icon: const Icon(Icons.more_vert, size: 20),
                          padding: EdgeInsets.zero,
                          onSelected: (action) async {
                            if (action == 'verify') {
                              await widget.bridge.markContactVerified(
                                contact.identityId,
                              );
                            } else {
                              await widget.bridge.removeContact(
                                contact.identityId,
                              );
                            }
                            if (mounted) _refreshFriends();
                          },
                          itemBuilder: (_) => const [
                            PopupMenuItem(
                              value: 'verify',
                              child: Text('Fingerprint checked in person'),
                            ),
                            PopupMenuItem(
                              value: 'remove',
                              child: Text('Remove friend'),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          SelectableText(
            'Signed name: ${contact.signedName}\n'
            '${contact.verified ? 'Identity verified' : 'Fingerprint not verified'}\n'
            '${contact.fingerprint}\n${contact.identityId}',
            key: Key('friend-details-${contact.identityId}'),
            style: TextStyle(
              fontSize: 12,
              height: 1.35,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    ),
  );
}
