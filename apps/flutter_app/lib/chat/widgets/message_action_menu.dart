import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../peer_message_action.dart';

class MessageActionMenu {
  const MessageActionMenu({
    this.buttonKey,
    this.onSelected,
    this.onReply,
    this.showReply = true,
    this.canEdit = false,
    this.canDelete = false,
    this.copyText,
    this.unavailableReason,
  });

  final Key? buttonKey;
  final ValueChanged<PeerMessageActionKind>? onSelected;
  final VoidCallback? onReply;
  final bool showReply, canEdit, canDelete;
  final String? copyText, unavailableReason;

  Future<void> show(
    BuildContext context, {
    Offset? pointer,
    String? details,
  }) async {
    final navigator = Navigator.of(context);
    final overlay = navigator.overlay!.context.findRenderObject() as RenderBox;
    final anchor = context.findRenderObject() as RenderBox;
    final bounds = pointer == null
        ? anchor.localToGlobal(Offset.zero, ancestor: overlay) & anchor.size
        : overlay.globalToLocal(pointer) & Size.zero;
    final tiles = [
      if (copyText != null) _MessageMenuItem.copy,
      if (showReply) _MessageMenuItem.reply,
      if (canEdit) _MessageMenuItem.edit,
      if (canDelete) _MessageMenuItem.delete,
      if (details != null) _MessageMenuItem.info,
    ];
    if (tiles.isEmpty) return;
    final maxWidth = (overlay.size.width - 32).clamp(13.0, 284.0);
    final columns = (maxWidth / 68).floor().clamp(1, tiles.length);
    final width = (columns * 68 + 12).clamp(13.0, maxWidth).toDouble();
    final selected = await showMenu<_MessageMenuItem>(
      context: context,
      position: RelativeRect.fromSize(bounds, overlay.size),
      requestFocus: false,
      menuPadding: EdgeInsets.zero,
      constraints: BoxConstraints.tightFor(width: width),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      items: [
        _ActionGridEntry(
          height:
              (tiles.length / columns).ceil() * 60 +
              12 +
              (unavailableReason == null ? 0 : 36),
          child: Padding(
            key: const Key('message-action-grid'),
            padding: const EdgeInsets.all(6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Wrap(
                  children: [
                    for (final tile in tiles)
                      SizedBox(
                        width: (width - 12) / columns,
                        height: 60,
                        child: TextButton(
                          onPressed:
                              tile.action == null ||
                                  onSelected != null ||
                                  (tile == _MessageMenuItem.reply &&
                                      onReply != null)
                              ? () => navigator.pop(tile)
                              : null,
                          style: TextButton.styleFrom(
                            foregroundColor: Theme.of(context)
                                .colorScheme
                                .onSurface,
                            padding: EdgeInsets.zero,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(tile.icon, size: 22),
                              const SizedBox(height: 4),
                              Text(
                                tile.label,
                                textAlign: TextAlign.center,
                                style: const TextStyle(fontSize: 11),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
                if (unavailableReason case final reason?)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(6, 4, 6, 2),
                    child: Text(
                      reason,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
    if (!context.mounted || selected == null) return;
    if (selected == _MessageMenuItem.copy) {
      await Clipboard.setData(ClipboardData(text: copyText!));
    } else if (selected == _MessageMenuItem.info) {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Message info'),
          content: SelectableText(details!),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    } else if (selected == _MessageMenuItem.reply && onReply != null) {
      onReply!();
    } else {
      onSelected?.call(selected.action!);
    }
  }
}

enum _MessageMenuItem {
  copy('Copy', Icons.copy_outlined),
  reply('Reply', Icons.reply_rounded, PeerMessageActionKind.reply),
  edit('Edit', Icons.edit_outlined, PeerMessageActionKind.edit),
  delete('Delete', Icons.delete_outline, PeerMessageActionKind.delete),
  info('Message info', Icons.info_outline);

  const _MessageMenuItem(this.label, this.icon, [this.action]);
  final String label;
  final IconData icon;
  final PeerMessageActionKind? action;
}

class _ActionGridEntry extends PopupMenuEntry<_MessageMenuItem> {
  const _ActionGridEntry({required this.child, required this.height});

  final Widget child;
  @override
  final double height;
  @override
  bool represents(_MessageMenuItem? value) => false;

  @override
  State<_ActionGridEntry> createState() => _ActionGridEntryState();
}

class _ActionGridEntryState extends State<_ActionGridEntry> {
  @override
  Widget build(BuildContext context) => widget.child;
}
