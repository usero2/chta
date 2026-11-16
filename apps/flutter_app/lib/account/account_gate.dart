import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../chat/chat_controller.dart';
import '../chat/chat_models.dart';
import '../chat/chat_shell.dart';
import '../chat/peer_history.dart';
import '../chat/peer_history_store.dart';
import '../chat/attachment_store.dart';
import '../chat/widgets/conversation_list.dart';
import '../chat/widgets/contact_details_sheet.dart';
import '../groups/group_blob_bridge.dart';
import '../groups/group_crypto_bridge.dart';
import '../groups/group_controller.dart';
import '../groups/group_transport.dart';
import '../groups/group_seed_client.dart';
import '../groups/group_room.dart';
import '../groups/group_dialogs.dart';
import '../relay/relay_crypto_bridge.dart';
import '../core/core_bridge.dart';
import '../notifications/incoming_notifications.dart';
import '../notifications/peer_history_notifications.dart';
import '../p2p/connection_page.dart';
import '../relay/relay_network.dart';
import '../profile/profile_controller.dart';
import '../profile/profile_page.dart';
import '../profile/profile_store.dart';
import '../routing/app_router.dart';
import 'account_controller.dart';
import 'account_models.dart';
import 'android_session_bridge.dart';
import 'contacts_page.dart';
import 'desktop_login.dart';
import 'recovery_download.dart';

class AccountGate extends StatefulWidget {
  const AccountGate({
    required this.controller,
    required this.chatController,
    required this.bridge,
    required this.router,
    this.profileController,
    this.peerHistoryStore,
    super.key,
  });

  final AccountController controller;
  final ChatController chatController;
  final AppBridge bridge;
  final AppRouter router;
  final ProfileController? profileController;
  final PeerHistoryStore? peerHistoryStore;

  @override
  State<AccountGate> createState() => _AccountGateState();
}

class _AccountGateState extends State<AccountGate> {
  late final ProfileController profileController;
  (String, AccountStatus)? preparationKey;
  Future<void>? preparation;

  @override
  void initState() {
    super.initState();
    profileController =
        widget.profileController ??
        ProfileController(
          createProfileStore(identityBridge: widget.controller.desktop),
        );
    if (widget.profileController == null) unawaited(profileController.load());
    widget.controller.addListener(_changed);
    widget.router.addListener(_routeChanged);
    widget.controller.initialize();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    widget.router.removeListener(_routeChanged);
    super.dispose();
  }

  void _routeChanged() => _syncRoute();

  void _changed() {
    final controller = widget.controller;
    if (controller.desktop != null &&
        controller.identity != null &&
        (controller.status == AccountStatus.ready ||
            controller.status == AccountStatus.pinSetup)) {
      final key = (controller.identity!.id, controller.status);
      if (preparationKey != key) {
        preparationKey = key;
        preparation = _prepareSession(controller.status == AccountStatus.ready);
      }
    } else {
      preparationKey = null;
      preparation = null;
    }
    _syncRoute();
    setState(() {});
  }

  Future<void> _prepareSession(bool ready) async {
    await profileController.load();
    if (profileController.error != null) throw profileController.error!;
    if (ready) await widget.chatController.reload();
  }

  Widget _prepared(Widget body) => preparation == null
      ? body
      : FutureBuilder<void>(
          future: preparation,
          builder: (context, snapshot) => snapshot.hasError
              ? Scaffold(
                  body: Center(
                    child: Text(
                      'Unable to load this identity: ${snapshot.error}',
                    ),
                  ),
                )
              : snapshot.connectionState == ConnectionState.done
              ? body
              : const Scaffold(
                  body: Center(child: CircularProgressIndicator()),
                ),
        );

  void _syncRoute() {
    final path = widget.router.path;
    switch (widget.controller.status) {
      case AccountStatus.needsIdentity || AccountStatus.chooseIdentity:
        widget.router.go('/identity', replace: true);
      case AccountStatus.pinSetup:
        widget.router.go('/identity/pin', replace: true);
      case AccountStatus.recoveryConfirmation:
        widget.router.go('/identity/new', replace: true);
      case AccountStatus.ready:
        final valid = widget.controller.supportsPinLockPreference
            ? isSessionRoute(path)
            : path.startsWith('/chats') ||
                  path == '/contacts' ||
                  path == '/profile' ||
                  path.startsWith('/connect');
        if (!valid) {
          final saved = widget.controller.rememberedRoute;
          widget.router.go(
            saved != null && isSessionRoute(saved) ? saved : '/chats',
            replace: true,
          );
        }
      case AccountStatus.loading || AccountStatus.failed:
        break;
    }
  }

  @override
  Widget build(BuildContext context) => switch (widget.controller.status) {
    AccountStatus.loading => const Scaffold(
      body: Center(child: CircularProgressIndicator()),
    ),
    AccountStatus.needsIdentity => _Welcome(controller: widget.controller),
    AccountStatus.chooseIdentity => DesktopIdentityPicker(
      controller: widget.controller,
    ),
    AccountStatus.pinSetup => _prepared(
      DesktopPinSetup(
        controller: widget.controller,
        profile: profileController,
      ),
    ),
    AccountStatus.recoveryConfirmation => _RecoveryConfirmation(
      controller: widget.controller,
    ),
    AccountStatus.ready => _prepared(
      _AuthenticatedHome(
        key: ValueKey(widget.controller.identity!.id),
        accountController: widget.controller,
        chatController: widget.chatController,
        bridge: widget.bridge,
        router: widget.router,
        profileController: profileController,
        peerHistoryStore: widget.peerHistoryStore,
      ),
    ),
    AccountStatus.failed => Scaffold(
      body: Center(
        child: Text('Unable to unlock identity\n${widget.controller.error}'),
      ),
    ),
  };
}

class _Welcome extends StatefulWidget {
  const _Welcome({required this.controller});
  final AccountController controller;

  @override
  State<_Welcome> createState() => _WelcomeState();
}

class _WelcomeState extends State<_Welcome> {
  final restorePasteController = TextEditingController();
  final restoreControllers = List.generate(24, (_) => TextEditingController());
  String? restoreInputError;

  String get restorePhrase => restoreControllers
      .map((controller) => controller.text.trim().toLowerCase())
      .join(' ');

  void _fillRestoreFields() {
    final words = restorePasteController.text.trim().toLowerCase().split(
      RegExp(r'\s+'),
    );
    if (words.length != 24) {
      setState(
        () => restoreInputError =
            'Recovery phrase must contain exactly 24 words.',
      );
      return;
    }
    for (var index = 0; index < restoreControllers.length; index++) {
      restoreControllers[index].text = words[index];
    }
    setState(() => restoreInputError = null);
  }

  @override
  void dispose() {
    restorePasteController.dispose();
    for (final controller in restoreControllers) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.all(32),
          children: [
            if (widget.controller.desktop != null)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const Key('back-to-identities'),
                  onPressed: widget.controller.showIdentityList,
                  icon: const Icon(Icons.arrow_back),
                  label: const Text('Back'),
                ),
              ),
            const Text(
              'chta',
              style: TextStyle(fontSize: 38, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 28),
            FilledButton.icon(
              key: const Key('create-identity'),
              onPressed: widget.controller.createIdentity,
              icon: const Icon(Icons.person_add_alt_1),
              label: const Text('Create new identity'),
            ),
            const SizedBox(height: 24),
            const Text(
              'Restore identity',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const Key('restore-phrase-paste'),
              controller: restorePasteController,
              minLines: 2,
              maxLines: 3,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(labelText: 'Paste 24 words'),
              onChanged: (value) {
                if (value.trim().split(RegExp(r'\s+')).length == 24) {
                  _fillRestoreFields();
                }
              },
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                key: const Key('fill-restore-fields'),
                onPressed: _fillRestoreFields,
                icon: const Icon(Icons.grid_view_outlined),
                label: const Text('Fill fields'),
              ),
            ),
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: restoreControllers.length,
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 180,
                mainAxisExtent: 68,
                crossAxisSpacing: 8,
                mainAxisSpacing: 8,
              ),
              itemBuilder: (context, index) => TextField(
                key: Key('restore-recovery-${index + 1}'),
                controller: restoreControllers[index],
                autocorrect: false,
                enableSuggestions: false,
                textAlign: TextAlign.center,
                decoration: InputDecoration(labelText: '${index + 1}'),
              ),
            ),
            if (restoreInputError != null)
              Text(
                restoreInputError!,
                style: const TextStyle(color: Colors.redAccent),
              ),
            const SizedBox(height: 12),
            OutlinedButton(
              key: const Key('restore-identity'),
              onPressed: () => widget.controller.restoreIdentity(restorePhrase),
              child: const Text('Restore identity'),
            ),
            if (widget.controller.error != null) ...[
              const SizedBox(height: 12),
              Text(
                '${widget.controller.error}',
                style: const TextStyle(color: Colors.redAccent),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}

class _RecoveryConfirmation extends StatefulWidget {
  const _RecoveryConfirmation({required this.controller});
  final AccountController controller;

  @override
  State<_RecoveryConfirmation> createState() => _RecoveryConfirmationState();
}

class _RecoveryConfirmationState extends State<_RecoveryConfirmation> {
  final confirmationControllers = List.generate(
    24,
    (_) => TextEditingController(),
  );

  @override
  void initState() {
    super.initState();
    _fillPhrase(widget.controller.pendingIdentity!.mnemonic);
  }

  @override
  void dispose() {
    for (final controller in confirmationControllers) {
      controller.dispose();
    }
    super.dispose();
  }

  String get confirmationPhrase => confirmationControllers
      .map((controller) => controller.text.trim().toLowerCase())
      .join(' ');

  void _fillPhrase(String phrase) {
    final words = phrase.split(' ');
    for (var index = 0; index < confirmationControllers.length; index++) {
      confirmationControllers[index].text = words[index];
    }
  }

  Future<void> _generateAgain() async {
    await widget.controller.createIdentity();
    if (!mounted) return;
    _fillPhrase(widget.controller.pendingIdentity!.mnemonic);
    setState(() {});
  }

  Future<void> _download(String phrase) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Save recovery phrase?'),
        content: const Text(
          'This file is unencrypted. Anyone with it can use your identity. '
          'Store it offline and delete unsafe copies.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Download .txt'),
          ),
        ],
      ),
    );
    if (accepted != true) return;
    try {
      await downloadRecoveryPhrase(phrase);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not save the recovery phrase.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final phrase = widget.controller.pendingIdentity!.mnemonic;
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(32),
            children: [
              Row(
                children: [
                  IconButton(
                    key: const Key('back-from-create-identity'),
                    tooltip: 'Back to sign in',
                    onPressed: widget.controller.cancelIdentityCreation,
                    icon: const Icon(Icons.arrow_back),
                  ),
                  const SizedBox(width: 4),
                  const Expanded(
                    child: Text(
                      'Create new identity',
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              const Text(
                'Keep these 24 words private. They unlock your identity.',
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    key: const Key('random-recovery-phrase'),
                    onPressed: _generateAgain,
                    icon: const Icon(Icons.casino_outlined),
                    label: const Text('Generate phrase'),
                  ),
                  OutlinedButton.icon(
                    key: const Key('download-recovery-phrase'),
                    onPressed: () => _download(phrase),
                    icon: const Icon(Icons.download_outlined),
                    label: const Text('Save as text file'),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              const Text(
                'Recovery phrase (24 words)',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: confirmationControllers.length,
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 180,
                  mainAxisExtent: 68,
                  crossAxisSpacing: 8,
                  mainAxisSpacing: 8,
                ),
                itemBuilder: (context, index) => TextField(
                  key: Key('confirm-recovery-${index + 1}'),
                  controller: confirmationControllers[index],
                  autocorrect: false,
                  enableSuggestions: false,
                  textAlign: TextAlign.center,
                  decoration: InputDecoration(labelText: '${index + 1}'),
                ),
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: () =>
                    widget.controller.confirmRecovery(confirmationPhrase),
                child: const Text('Create identity'),
              ),
              if (widget.controller.error != null)
                Text(
                  '${widget.controller.error}',
                  style: const TextStyle(color: Colors.redAccent),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AuthenticatedHome extends StatefulWidget {
  const _AuthenticatedHome({
    required this.accountController,
    required this.chatController,
    required this.bridge,
    required this.router,
    required this.profileController,
    this.peerHistoryStore,
    super.key,
  });
  final AccountController accountController;
  final ChatController chatController;
  final AppBridge bridge;
  final AppRouter router;
  final ProfileController profileController;
  final PeerHistoryStore? peerHistoryStore;

  @override
  State<_AuthenticatedHome> createState() => _AuthenticatedHomeState();
}

class _AuthenticatedHomeState extends State<_AuthenticatedHome> {
  final connectionPageKey = GlobalKey<ConnectionPageState>();
  late final PeerHistory peerHistory;
  late final IncomingNotifications notifications;
  PeerHistoryNotifications? historyNotifications;
  List<ContactView> chatContacts = const [];
  Set<String> onlinePeers = const {};
  bool historyReady = false;
  Object? historyError;
  late int index;
  String? targetContactId;
  String? initialConversationId;
  bool showingPeerChat = false;
  int contactsRefreshToken = 0;
  RelayNetwork? relayNetwork;
  GroupController? groups;
  GroupTransport? groupTransport;
  Future<void>? groupsPreparation;
  Object? groupsError;
  String? targetGroupId;
  bool exiting = false;

  @override
  void initState() {
    super.initState();
    widget.router.addListener(_routeChanged);
    _readRoute();
    unawaited(widget.accountController.rememberRoute(widget.router.path));
    widget.chatController.initialize();
    notifications = IncomingNotifications(
      identityId: widget.accountController.identity!.id,
    );
    unawaited(notifications.initialize());
    peerHistory = PeerHistory(
      attachments: kIsWeb || widget.accountController.bridge is AttachmentBridge
          ? createAttachmentStore(bridge: widget.accountController.bridge)
          : null,
      store:
          widget.peerHistoryStore ??
          createPeerHistoryStore(
            identityBridge: widget.accountController.desktop,
          ),
    );
    peerHistory.addListener(_historyChanged);
    _loadHistory();
    _loadChatContacts();
    final bridge = widget.bridge;
    if (bridge is GroupCryptoBridge && bridge is GroupBlobBridge) {
      final controller = GroupController(
        ownerId: widget.accountController.identity!.id,
        crypto: bridge as GroupCryptoBridge,
        blobs: bridge as GroupBlobBridge,
        attachments: createAttachmentStore(bridge: bridge),
        displayName: () => widget.profileController.name,
        notifications: notifications,
      );
      groups = controller;
      controller.addListener(_groupsChanged);
      groupsPreparation = controller
          .initialize()
          .then((_) {
            if (mounted) {
              setState(() {});
              unawaited(_attachGroupTransport());
            }
          })
          .catchError((Object caught) {
            if (mounted) setState(() => groupsError = caught);
          });
    }
  }

  void _groupsChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _attachGroupTransport() async {
    final controller = groups, network = relayNetwork, bridge = widget.bridge;
    if (!mounted ||
        controller?.ready != true ||
        network == null ||
        groupTransport != null ||
        bridge is! GroupCryptoBridge ||
        bridge is! RelayCryptoBridge) {
      return;
    }
    final seed = GroupSeedClient(
      account: bridge,
      relayCrypto: bridge as RelayCryptoBridge,
      crypto: bridge as GroupCryptoBridge,
      network: network,
    );
    final transport = GroupTransport(
      ownerId: widget.accountController.identity!.id,
      crypto: bridge as GroupCryptoBridge,
      network: network,
      signaling: SeedGroupSignaling(seed),
    );
    groupTransport = transport;
    try {
      await controller!.attachTransport(transport);
    } catch (_) {
      if (mounted) {
        setState(
          () => groupsError = StateError('Group connection unavailable'),
        );
      }
    }
  }

  Future<void> _createGroup() async {
    final controller = groups;
    if (controller?.ready != true) return;
    await _loadChatContacts();
    if (!mounted) return;
    final result = await showCreateGroupDialog(context, chatContacts);
    if (result == null || !mounted) return;
    try {
      final id = await controller!.createGroup(result.$1, result.$2);
      if (mounted) widget.router.go(conversationRoute(id));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not create the group.')),
        );
      }
    }
  }

  Future<void> _groupDetails(String id) async {
    final controller = groups, group = groups?.group(id);
    if (controller == null || group == null) return;
    await showGroupDetails(
      context,
      group: group,
      ownId: controller.ownerId,
      contacts: chatContacts,
      onInvite: (peer) => controller.invite(id, peer),
      onRemove: (peer) => controller.removeMember(id, peer),
      onLeave: () => controller.leaveGroup(id),
    );
  }

  Future<void> _deleteGroupChat(String id) async {
    if (await confirmDeleteGroupChat(context)) {
      await groups?.clearConversation(id);
    }
  }

  void _conversationAction(String id, ConversationAction action) {
    unawaited(_manageConversation(id, action));
  }

  Future<void> _manageConversation(String id, ConversationAction action) async {
    if (!id.startsWith('group:') && !id.startsWith('did:cht:')) {
      final room = widget.chatController.conversations
          .where((c) => c.id == id)
          .firstOrNull;
      if (room == null || !mounted || action != ConversationAction.delete) {
        return;
      }
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Delete ${room.title}?'),
          content: const Text(
            'Remove this room and its messages from this device?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete chat'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      if (await widget.chatController.deleteConversation(id)) {
        if (mounted) {
          setState(() {});
          if (initialConversationId == id) widget.router.go('/chats');
        }
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not delete the chat. Try again.'),
          ),
        );
      }
      return;
    }
    if (id.startsWith('group:')) {
      if (action == ConversationAction.details) {
        await _groupDetails(id);
      } else {
        await _deleteGroupChat(id);
      }
      return;
    }
    final contact = peerHistory
        .withSavedConversations(chatContacts)
        .where((c) => c.identityId == id)
        .firstOrNull;
    if (contact == null || !mounted) return;
    if (action == ConversationAction.details) {
      await showContactDetailsSheet(context, contact);
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete chat?'),
        content: Text(
          'Clear your chat history with ${contact.displayName} on this device?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete chat'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    connectionPageKey.currentState?.cancelConversationWork(id);
    await peerHistory.clearConversation(id);
  }

  Future<void> _reviewGroupInvitations() async {
    final controller = groups;
    if (controller == null) return;
    await showGroupInvitations(
      context,
      contacts: chatContacts,
      invitations: controller.invitations,
      onAccept: (id) async {
        final group = controller.invitations
            .where((i) => i.id == id)
            .firstOrNull
            ?.groupId;
        await controller.acceptInvitation(id);
        if (mounted && group != null) {
          widget.router.go(conversationRoute(group));
        }
      },
      onDecline: controller.declineInvitation,
    );
  }

  List<ConversationView> _peerConversations() => [
    for (final contact in peerHistory.withSavedConversations(chatContacts))
      ConversationView(
        id: contact.identityId,
        title: contact.displayName,
        avatarBase64: contact.avatarBase64,
        preview:
            peerHistory.messagesFor(contact.identityId).lastOrNull?.text ??
            (onlinePeers.contains(contact.identityId)
                ? 'Connected securely'
                : 'Offline'),
        updatedAtMilliseconds:
            peerHistory
                .messagesFor(contact.identityId)
                .lastOrNull
                ?.sentAtMilliseconds ??
            0,
        messages: const [],
      ),
    ...?groups?.conversations,
  ];
  Widget _groupChat(String id) {
    final controller = groups, group = groups?.group(id);
    if (controller == null || !controller.ready || group == null) {
      return SafeArea(
        child: Column(
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: IconButton(
                tooltip: 'Back to chats',
                icon: const Icon(Icons.arrow_back),
                onPressed: () => widget.router.go('/chats'),
              ),
            ),
            Expanded(
              child: Center(
                child: groupsError == null && controller?.ready != true
                    ? const CircularProgressIndicator()
                    : const Text('Group unavailable'),
              ),
            ),
          ],
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 720;
        final room = GroupRoom(
          group: group,
          ownId: controller.ownerId,
          messages: controller.messagesFor(id),
          enabled: controller.canSend(id),
          disabledReason: controller.disabledReason(id),
          error: controller.error,
          onlineCount: controller.onlineCount(id),
          onSend: (text) => controller.sendText(id, text),
          onSendBatch: (caption, files) =>
              controller.sendBatch(id, caption, files),
          openFile: controller.openFile,
          progressFor: controller.progressFor,
          onDetails: () => unawaited(_groupDetails(id)),
          onDelete: () => unawaited(_deleteGroupChat(id)),
          onBack: () => widget.router.go('/chats'),
        );
        if (!wide) return room;
        return Row(
          children: [
            SizedBox(
              width: 304,
              child: ConversationList(
                conversations: [
                  ...widget.chatController.conversations,
                  ..._peerConversations(),
                ],
                selectedId: id,
                onSelected: (selected) =>
                    widget.router.go(conversationRoute(selected)),
                onCreateGroup: () => unawaited(_createGroup()),
                onActionSelected: _conversationAction,
              ),
            ),
            const VerticalDivider(width: 1),
            Expanded(child: room),
          ],
        );
      },
    );
  }

  Future<void> _loadHistory() async {
    try {
      await peerHistory.load(widget.accountController.identity!.id);
      if (!mounted) return;
      historyNotifications = PeerHistoryNotifications(
        history: peerHistory,
        notifications: notifications,
      );
      if (mounted) setState(() => historyReady = true);
      if (mounted) await _loadChatContacts();
    } catch (caught) {
      if (mounted) setState(() => historyError = caught);
    }
  }

  void _historyChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadChatContacts() async {
    final contacts = await widget.bridge.contacts();
    if (mounted) {
      if (historyReady) peerHistory.rememberContacts(contacts);
      setState(() => chatContacts = contacts);
    }
  }

  @override
  void dispose() {
    widget.router.removeListener(_routeChanged);
    historyNotifications?.dispose();
    notifications.dispose();
    peerHistory.removeListener(_historyChanged);
    peerHistory.dispose();
    groups?.removeListener(_groupsChanged);
    unawaited(groups?.close());
    super.dispose();
  }

  void _readRoute() {
    final path = widget.router.path;
    targetGroupId = groupIdFromChatRoute(path);
    if (path == '/contacts') {
      index = 1;
      targetContactId = null;
      initialConversationId = null;
      showingPeerChat = false;
    } else if (path.startsWith('/connect')) {
      index = 2;
      targetContactId = contactIdFromConnectRoute(path);
      initialConversationId = null;
      showingPeerChat = false;
    } else if (path == '/profile') {
      index = 3;
      targetContactId = null;
      initialConversationId = null;
      showingPeerChat = false;
    } else {
      index = 0;
      targetContactId = contactIdFromChatRoute(path);
      showingPeerChat = targetContactId != null;
      initialConversationId = showingPeerChat
          ? null
          : targetGroupId != null
          ? null
          : conversationIdFromRoute(path);
    }
  }

  void _routeChanged() {
    if (!mounted) return;
    unawaited(widget.accountController.rememberRoute(widget.router.path));
    _loadChatContacts();
    setState(() {
      _readRoute();
      if (index == 1) contactsRefreshToken++;
    });
  }

  void _selectDestination(int value) {
    switch (value) {
      case 0:
        widget.router.go('/chats');
      case 1:
        widget.router.go('/contacts');
      case 2:
        widget.router.go('/connect');
      case 3:
        widget.router.go('/profile');
    }
  }

  void _chatWith(ContactView contact) {
    widget.router.go(contactChatRoute(contact.identityId));
  }

  Future<void> _switchIdentity() async {
    await groups?.flush();
    await peerHistory.flush();
    await widget.accountController.lock();
  }

  Future<void> _setPinLock(bool enabled) async {
    if (!enabled) {
      await widget.accountController.rememberRoute(widget.router.path);
    }
    await widget.accountController.setPinLock(enabled);
  }

  Future<void> _closeApp() async {
    if (exiting) return;
    exiting = true;
    try {
      await groups?.flush();
      await peerHistory.flush();
      await widget.accountController.rememberRoute(widget.router.path);
      await widget.accountController.flushSessionWrites();
      if (widget.accountController.pinLockEnabled) {
        await widget.accountController.lock();
      }
      await SystemNavigator.pop();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Unable to close the app. Please try again.'),
          ),
        );
      }
    } finally {
      exiting = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final conversationOpen =
        index == 0 && conversationIdFromRoute(widget.router.path) != null;
    final connectionPage = ConnectionPage(
      key: connectionPageKey,
      onRelayNetworkReady: (network) {
        if (mounted && !identical(network, relayNetwork)) {
          setState(() => relayNetwork = network);
          unawaited(_attachGroupTransport());
        }
      },
      accountBridge: widget.bridge,
      profileController: widget.profileController,
      targetContactId: targetContactId,
      chatMode: showingPeerChat,
      onPeerAuthenticated: (contact) {
        unawaited(_loadChatContacts());
        if (index == 2) {
          widget.router.go(contactChatRoute(contact.identityId));
        } else if (index == 1) {
          setState(() => contactsRefreshToken++);
        }
      },
      onConnectRequested: (contact) =>
          widget.router.go(contactConnectRoute(contact.identityId)),
      onChatSelected: _chatWith,
      chatController: widget.chatController,
      peerHistory: peerHistory,
      onRoomSelected: (id) => widget.router.go(conversationRoute(id)),
      onBackToChats: () => widget.router.go('/chats'),
      onCreateGroup: groups?.ready == true
          ? () => unawaited(_createGroup())
          : null,
      extraConversations: groups?.conversations ?? const [],
      onConversationAction: _conversationAction,
      onOnlinePeersChanged: (peers) {
        if (mounted && !setEquals(peers, onlinePeers)) {
          setState(() => onlinePeers = peers);
        }
      },
    );
    final home = Scaffold(
      appBar: groups?.invitations.isNotEmpty == true
          ? AppBar(
              leading: const Icon(Icons.group_add_outlined),
              title: Text('Group invitations (${groups!.invitations.length})'),
              actions: [
                TextButton(
                  onPressed: () => unawaited(_reviewGroupInvitations()),
                  child: const Text('Review'),
                ),
              ],
            )
          : null,
      body: !historyReady
          ? Center(
              child: historyError == null
                  ? const CircularProgressIndicator()
                  : const Text(
                      'Unable to load saved chat history. Please reopen the app.',
                    ),
            )
          : IndexedStack(
              index: index,
              children: [
                if (showingPeerChat)
                  connectionPage
                else if (targetGroupId != null)
                  _groupChat(targetGroupId!)
                else
                  ChatShell(
                    controller: widget.chatController,
                    coreBridge: widget.bridge,
                    initialConversationId: initialConversationId,
                    onConversationSelected: (id) =>
                        widget.router.go(conversationRoute(id)),
                    onBackToConversations: () => widget.router.go('/chats'),
                    peerConversations: [
                      ...?groups?.conversations,
                      for (final contact in peerHistory.withSavedConversations(
                        chatContacts,
                      ))
                        ConversationView(
                          id: contact.identityId,
                          title: contact.displayName,
                          avatarBase64: contact.avatarBase64,
                          preview:
                              peerHistory
                                  .messagesFor(contact.identityId)
                                  .lastOrNull
                                  ?.text ??
                              (onlinePeers.contains(contact.identityId)
                                  ? 'Connected securely'
                                  : 'Offline'),
                          updatedAtMilliseconds:
                              peerHistory
                                  .messagesFor(contact.identityId)
                                  .lastOrNull
                                  ?.sentAtMilliseconds ??
                              0,
                          messages: const [],
                        ),
                    ],
                    onPeerSelected: (id) =>
                        widget.router.go(conversationRoute(id)),
                    onConversationAction: _conversationAction,
                    onCreateGroup: groups?.ready == true
                        ? () => unawaited(_createGroup())
                        : null,
                  ),
                ContactsPage(
                  relayNetwork: relayNetwork,
                  bridge: widget.bridge,
                  identity: widget.accountController.identity!,
                  profileController: widget.profileController,
                  refreshToken: contactsRefreshToken,
                  peerHistory: peerHistory,
                  onChat: _chatWith,
                ),
                if (showingPeerChat)
                  const SizedBox.shrink()
                else
                  connectionPage,
                ProfilePage(
                  notifications: notifications,
                  controller: widget.profileController,
                  identity: widget.accountController.identity!,
                  onSwitchIdentity: widget.accountController.desktop == null
                      ? null
                      : _switchIdentity,
                  pinLockEnabled:
                      widget.accountController.supportsPinLockPreference
                      ? widget.accountController.pinLockEnabled
                      : null,
                  onPinLockChanged:
                      widget.accountController.supportsPinLockPreference
                      ? _setPinLock
                      : null,
                  onLockApp: widget.accountController.supportsPinLockPreference
                      ? _switchIdentity
                      : null,
                ),
              ],
            ),
      bottomNavigationBar: conversationOpen
          ? null
          : NavigationBar(
              selectedIndex: index,
              onDestinationSelected: _selectDestination,
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.chat_bubble_outline),
                  label: 'Chats',
                ),
                NavigationDestination(
                  icon: Icon(Icons.people_outline),
                  label: 'Contacts',
                ),
                NavigationDestination(
                  icon: Icon(Icons.hub_outlined),
                  label: 'Connect',
                ),
                NavigationDestination(
                  icon: Icon(Icons.person_outline),
                  label: 'Profile',
                ),
              ],
            ),
    );
    return conversationOpen ||
            widget.accountController.supportsPinLockPreference
        ? PopScope<void>(
            canPop: false,
            onPopInvokedWithResult: (didPop, _) {
              if (didPop) return;
              if (conversationOpen) {
                widget.router.go('/chats');
              } else {
                unawaited(_closeApp());
              }
            },
            child: home,
          )
        : home;
  }
}
