import 'package:flutter/material.dart';

import '../core/core_bridge.dart';
import 'chat_controller.dart';
import 'chat_models.dart';
import 'widgets/chat_room.dart';
import 'widgets/conversation_list.dart';

class ChatShell extends StatefulWidget {
  const ChatShell({
    required this.controller,
    required this.coreBridge,
    this.initialConversationId,
    this.onConversationSelected,
    this.onBackToConversations,
    this.showSidebar = true,
    this.peerConversations = const [],
    this.onPeerSelected,
    this.onCreateGroup,
    this.onConversationAction,
    super.key,
  });

  final ChatController controller;
  final CoreBridge coreBridge;
  final String? initialConversationId;
  final ValueChanged<String>? onConversationSelected;
  final VoidCallback? onBackToConversations;
  final bool showSidebar;
  final List<ConversationView> peerConversations;
  final ValueChanged<String>? onPeerSelected;
  final VoidCallback? onCreateGroup;
  final ConversationActionCallback? onConversationAction;

  @override
  State<ChatShell> createState() => _ChatShellState();
}

class _ChatShellState extends State<ChatShell> {
  static const _narrowBreakpoint = 720.0;

  bool _mobileRoomOpen = false;
  String? _appliedInitialConversationId;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_controllerChanged);
    widget.controller.initialize();
    _deferInitialConversation();
  }

  @override
  void didUpdateWidget(covariant ChatShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_controllerChanged);
      widget.controller.addListener(_controllerChanged);
      widget.controller.initialize();
    }
    if (oldWidget.initialConversationId != widget.initialConversationId) {
      if (widget.initialConversationId == null) _mobileRoomOpen = false;
      _appliedInitialConversationId = null;
      _deferInitialConversation();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_controllerChanged);
    super.dispose();
  }

  void _controllerChanged() {
    if (mounted) {
      _applyInitialConversation();
      setState(() {});
    }
  }

  void _deferInitialConversation() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _applyInitialConversation();
      setState(() {});
    });
  }

  void _applyInitialConversation() {
    final id = widget.initialConversationId;
    if (id == null ||
        id == _appliedInitialConversationId ||
        widget.controller.status != ChatControllerStatus.ready ||
        !widget.controller.conversations.any((item) => item.id == id)) {
      return;
    }
    _appliedInitialConversationId = id;
    _mobileRoomOpen = true;
    widget.controller.selectConversation(id);
  }

  void _openConversation(String id, {required bool narrow}) {
    if (widget.peerConversations.any((room) => room.id == id)) {
      widget.onPeerSelected?.call(id);
      return;
    }
    widget.controller.selectConversation(id);
    widget.onConversationSelected?.call(id);
    if (narrow) {
      setState(() => _mobileRoomOpen = true);
    }
  }

  void _showConversations() {
    setState(() => _mobileRoomOpen = false);
    widget.onBackToConversations?.call();
  }

  @override
  Widget build(BuildContext context) =>
      Scaffold(body: SafeArea(child: _buildBody()));

  Widget _buildBody() => switch (widget.controller.status) {
    ChatControllerStatus.loading => const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(),
          SizedBox(height: 16),
          Text('Loading chats…'),
        ],
      ),
    ),
    ChatControllerStatus.failed => const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline, size: 32),
          SizedBox(height: 12),
          Text('Unable to load chats'),
        ],
      ),
    ),
    ChatControllerStatus.ready => LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth <= _narrowBreakpoint;
        final selected = widget.controller.conversations.isEmpty
            ? null
            : widget.controller.selectedConversation;
        if (!widget.showSidebar && selected == null) {
          return const Center(child: Text('Select a chat'));
        }
        if (narrow || !widget.showSidebar) {
          return (_mobileRoomOpen || !widget.showSidebar) && selected != null
              ? ChatRoom(
                  key: const Key('chat-room'),
                  conversation: selected,
                  onSend: widget.controller.sendText,
                  onSendAttachment: widget.controller.sendAttachment,
                  onSendBatch: widget.controller.sendBatch,
                  onBack: _showConversations,
                  onDelete: widget.onConversationAction == null
                      ? null
                      : () => widget.onConversationAction!(
                          selected.id,
                          ConversationAction.delete,
                        ),
                )
              : ConversationList(
                  key: const Key('conversation-list'),
                  conversations: [
                    ...widget.controller.conversations,
                    ...widget.peerConversations,
                  ],
                  selectedId: selected?.id ?? '',
                  onSelected: (id) => _openConversation(id, narrow: true),
                  onCreateGroup: widget.onCreateGroup,
                  onActionSelected: widget.onConversationAction,
                );
        }

        return Row(
          children: [
            SizedBox(
              width: 340,
              child: ConversationList(
                key: const Key('conversation-list'),
                conversations: [
                  ...widget.controller.conversations,
                  ...widget.peerConversations,
                ],
                selectedId: selected?.id ?? '',
                onSelected: (id) => _openConversation(id, narrow: false),
                onCreateGroup: widget.onCreateGroup,
                onActionSelected: widget.onConversationAction,
              ),
            ),
            const VerticalDivider(width: 1, thickness: 1),
            Expanded(
              child: selected == null
                  ? Center(
                      child: Text(
                        widget.peerConversations.isEmpty
                            ? 'No chats yet'
                            : 'Select a chat',
                      ),
                    )
                  : ChatRoom(
                      key: const Key('chat-room'),
                      conversation: selected,
                      onBack: widget.onBackToConversations == null
                          ? null
                          : _showConversations,
                      onSend: widget.controller.sendText,
                      onSendAttachment: widget.controller.sendAttachment,
                      onSendBatch: widget.controller.sendBatch,
                      onDelete: widget.onConversationAction == null
                          ? null
                          : () => widget.onConversationAction!(
                              selected.id,
                              ConversationAction.delete,
                            ),
                    ),
            ),
          ],
        );
      },
    ),
  };
}
