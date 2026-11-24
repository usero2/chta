import 'package:flutter/material.dart';

import '../chat_models.dart';
import '../../profile/profile_avatar.dart';

enum ConversationAction { details, delete }

typedef ConversationActionCallback = void Function(
  String id,
  ConversationAction action,
);

class ConversationList extends StatelessWidget {
  const ConversationList({
    required this.conversations,
    required this.selectedId,
    required this.onSelected,
    this.onCreateGroup,
    this.onActionSelected,
    super.key,
  });

  final List<ConversationView> conversations;
  final String selectedId;
  final ValueChanged<String> onSelected;
  final VoidCallback? onCreateGroup;
  final ConversationActionCallback? onActionSelected;

  List<PopupMenuEntry<ConversationAction>> _actions(String id) => [
    if (id.startsWith('did:cht:') || id.startsWith('group:'))
      PopupMenuItem(
        value: ConversationAction.details,
        child: Text(
          id.startsWith('group:') ? 'Group details' : 'Contact details',
        ),
      ),
    const PopupMenuItem(
      value: ConversationAction.delete,
      child: Text('Delete chat'),
    ),
  ];

  Future<void> _showActions(BuildContext context, String id) async {
    final box = context.findRenderObject() as RenderBox;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final origin = box.localToGlobal(Offset.zero, ancestor: overlay);
    final action = await showMenu<ConversationAction>(
      context: context,
      position: RelativeRect.fromRect(
        origin & box.size,
        Offset.zero & overlay.size,
      ),
      items: _actions(id),
    );
    if (action != null) onActionSelected?.call(id, action);
  }

  @override
  Widget build(BuildContext context) => Material(
    color: const Color(0xFF1C1C1E),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 14, 12, 8),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  'chta',
                  style: TextStyle(
                    color: Color(0xFF9AE585),
                    fontSize: 25,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.5,
                  ),
                ),
              ),
              if (onCreateGroup != null)
                IconButton(
                  key: const Key('create-group-button'),
                  tooltip: 'Create group',
                  onPressed: onCreateGroup,
                  icon: const Icon(Icons.add),
                ),
            ],
          ),
        ),
        Expanded(
          child: conversations.isEmpty
              ? const Center(child: Text('No chats yet'))
              : ListView.builder(
                  itemCount: conversations.length,
                  itemBuilder: (context, index) {
                    final conversation = conversations[index];
                    final selected = conversation.id == selectedId;
                    final managed = onActionSelected != null;
                    return Builder(
                      builder: (rowContext) => Material(
                        color: selected
                            ? const Color(0xFF2C2C2E)
                            : Colors.transparent,
                        child: InkWell(
                          key: Key('conversation-${conversation.id}'),
                          onTap: () => onSelected(conversation.id),
                          onLongPress: managed
                              ? () => _showActions(rowContext, conversation.id)
                              : null,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 18,
                              vertical: 14,
                            ),
                            child: Row(
                              children: [
                                ProfileAvatar(
                                  key: Key(
                                    'conversation-avatar-${conversation.id}',
                                  ),
                                  name: conversation.title,
                                  avatarBase64: conversation.avatarBase64,
                                  selected: selected,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        conversation.title,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        conversation.preview,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: Color(0xFF8E8E93),
                                          fontSize: 13,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                if (managed)
                                  PopupMenuButton<ConversationAction>(
                                    key: Key(
                                      'conversation-menu-${conversation.id}',
                                    ),
                                    tooltip: 'Chat actions',
                                    icon: const Icon(Icons.more_vert),
                                    onSelected: (action) => onActionSelected!(
                                      conversation.id,
                                      action,
                                    ),
                                    itemBuilder: (_) =>
                                        _actions(conversation.id),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    ),
  );
}
