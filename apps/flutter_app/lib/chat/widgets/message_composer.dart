import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../chat_attachment.dart';
import '../attachment_files.dart';
import 'message_bubble.dart';
import 'pending_attachment_tray.dart';
import 'attachment_picker_sheet.dart';

typedef ComposerEdit = ({
  String id,
  String original,
  Future<bool> Function(String) save,
});

class MessageComposer extends StatefulWidget {
  const MessageComposer({
    required this.onSend,
    this.onSendAttachment,
    this.onSendBatch,
    this.controller,
    this.edit,
    this.onCancelEdit,
    this.inputKey = const Key('message-input'),
    this.sendKey = const Key('send-message'),
    this.pickAttachments,
    this.maxAttachmentBytes = ChatAttachment.maxStreamedBytes,
    super.key,
  });
  final Future<bool> Function(String) onSend;
  final Future<bool> Function(ChatAttachment)? onSendAttachment;
  final Future<bool> Function(String, List<ChatAttachment>)? onSendBatch;
  final TextEditingController? controller;
  final ComposerEdit? edit;
  final VoidCallback? onCancelEdit;
  final Key inputKey;
  final Key sendKey;
  final Future<List<ChatAttachment>> Function(AttachmentPickKind)?
  pickAttachments;
  final int maxAttachmentBytes;
  @override
  State<MessageComposer> createState() => _MessageComposerState();
}

class _MessageComposerState extends State<MessageComposer> {
  late final _draftController = widget.controller ?? TextEditingController();
  final _editController = TextEditingController();
  final _focus = FocusNode();
  bool get _editing => widget.edit != null;
  TextEditingController get _textController =>
      _editing ? _editController : _draftController;

  @override
  void initState() {
    super.initState();
    _loadEdit();
  }

  @override
  void didUpdateWidget(covariant MessageComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.edit?.id != widget.edit?.id) _loadEdit();
  }

  void _loadEdit() {
    final edit = widget.edit;
    if (edit == null) return;
    _editController.value = TextEditingValue(
      text: edit.original,
      selection: TextSelection.collapsed(offset: edit.original.length),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.edit?.id == edit.id) _focus.requestFocus();
    });
  }

  late final _keepDraftWhileSending = TextInputFormatter.withFunction(
    (previous, next) => _sending ? previous : next,
  );
  final _attachments = <ChatAttachment>[];
  bool _sending = false;
  bool _picking = false;
  bool _formatting = false;
  bool _preview = false;

  bool get _isNativeDesktop =>
      !kIsWeb &&
      switch (defaultTargetPlatform) {
        TargetPlatform.windows ||
        TargetPlatform.macOS ||
        TargetPlatform.linux => true,
        _ => false,
      };

  KeyEventResult _handleInputKey(FocusNode node, KeyEvent event) {
    const enter = SingleActivator(LogicalKeyboardKey.enter);
    const numpadEnter = SingleActivator(LogicalKeyboardKey.numpadEnter);
    const controlEnter = SingleActivator(
      LogicalKeyboardKey.enter,
      control: true,
    );
    final keyboard = HardwareKeyboard.instance;
    final desktopEnter =
        _isNativeDesktop &&
        (enter.accepts(event, keyboard) ||
            numpadEnter.accepts(event, keyboard));
    if (!desktopEnter && !controlEnter.accepts(event, keyboard)) {
      return KeyEventResult.ignored;
    }

    // Let an input method commit its current text before Enter can send it.
    final composing = _textController.value.composing;
    if (composing.isValid && !composing.isCollapsed) {
      return KeyEventResult.ignored;
    }
    if (event is KeyDownEvent) unawaited(_submit());
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    _focus.dispose();
    _editController.dispose();
    if (widget.controller == null) _draftController.dispose();
    super.dispose();
  }

  Future<void> _openAttachmentPicker() async {
    final kind = !kIsWeb && defaultTargetPlatform == TargetPlatform.android
        ? AttachmentPickKind.file
        : await showAttachmentPickerSheet(context);
    if (kind != null && mounted) await _pick(kind);
  }

  Future<void> _pick(AttachmentPickKind kind) async {
    if (_picking || _sending) return;
    setState(() => _picking = true);
    try {
      final chosen =
          await (widget.pickAttachments?.call(kind) ??
              pickChatAttachments(kind, maxBytes: widget.maxAttachmentBytes));
      if (!mounted) return;
      if (chosen.any((a) => a.size > widget.maxAttachmentBytes)) {
        throw FormatException(
          'Maximum file size is ${widget.maxAttachmentBytes ~/ (1024 * 1024)} MB.',
        );
      }
      if (_attachments.length + chosen.length > 5 ||
          [
                ..._attachments,
                ...chosen,
              ].where((a) => !a.isStreamed).fold<int>(0, (n, a) => n + a.size) >
              ChatAttachment.maxBytes) {
        throw const FormatException('Attach up to 5 files, 100 MB total.');
      }
      setState(() => _attachments.addAll(chosen));
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              error is FormatException ? error.message : 'Could not open file.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _submit() async {
    if (_sending || _picking) return;
    final edit = widget.edit;
    final text = _textController.text.trim();
    if (text.isEmpty && (edit != null || _attachments.isEmpty)) return;
    setState(() => _sending = true);
    try {
      if (edit != null) {
        final saved = text == edit.original.trim() || await edit.save(text);
        if (saved && mounted && widget.edit?.id == edit.id) {
          widget.onCancelEdit?.call();
        }
        return;
      }
      if (_attachments.isNotEmpty && widget.onSendBatch != null) {
        final queued = await widget.onSendBatch!(
          _draftController.text,
          List.of(_attachments),
        );
        if (!mounted) return;
        if (queued) {
          _draftController.clear();
          setState(() => _attachments.clear());
        }
        return;
      }
      if (_draftController.text.trim().isNotEmpty) {
        if (!await widget.onSend(_draftController.text)) return;
        if (!mounted) return;
        _draftController.clear();
      }
      for (final attachment in List<ChatAttachment>.of(_attachments)) {
        final sent = await widget.onSendAttachment?.call(attachment) ?? false;
        if (!mounted) return;
        // Failed queued transfers can be retried from the message bubble.
        if (!sent) return;
        setState(() => _attachments.remove(attachment));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _wrap(String before, [String? after]) {
    final text = _textController.text;
    final selection = _textController.selection;
    final start = selection.isValid ? selection.start : text.length;
    final end = selection.isValid ? selection.end : text.length;
    final selected = text.substring(start, end);
    _textController.value = TextEditingValue(
      text: text.replaceRange(start, end, '$before$selected${after ?? before}'),
      selection: TextSelection(
        baseOffset: start + before.length,
        extentOffset: start + before.length + selected.length,
      ),
    );
    setState(() {});
  }

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(
      color: Color(0xFF1C1C1E),
      border: Border(top: BorderSide(color: Color(0xFF3A3A3C))),
    ),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.edit case final edit?)
            ListTile(
              dense: true,
              contentPadding: const EdgeInsetsDirectional.only(start: 8),
              visualDensity: VisualDensity.compact,
              leading: const Icon(Icons.edit_outlined, size: 20),
              title: const Text('Editing message'),
              subtitle: Text(
                edit.original,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: IconButton(
                tooltip: 'Cancel edit',
                onPressed: _sending ? null : widget.onCancelEdit,
                icon: const Icon(Icons.close),
              ),
            ),
          if (!_editing && _attachments.isNotEmpty)
            PendingAttachmentTray(
              files: _attachments,
              onRemove: _sending
                  ? null
                  : (index) => setState(() => _attachments.removeAt(index)),
            ),
          if (_picking) const LinearProgressIndicator(),
          if (_formatting)
            SizedBox(
              height: 40,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  _format(Icons.format_bold, 'Bold', () => _wrap('**')),
                  _format(Icons.format_italic, 'Italic', () => _wrap('*')),
                  _format(
                    Icons.strikethrough_s,
                    'Strikethrough',
                    () => _wrap('~~'),
                  ),
                  _format(Icons.code, 'Code', () => _wrap('`')),
                  _format(
                    Icons.data_object,
                    'Code block',
                    () => _wrap('```\n', '\n```'),
                  ),
                  _format(Icons.title, 'Heading', () => _wrap('## ', '')),
                  _format(
                    Icons.format_list_bulleted,
                    'List',
                    () => _wrap('- ', ''),
                  ),
                  _format(Icons.checklist, 'Task', () => _wrap('- [ ] ', '')),
                  _format(Icons.format_quote, 'Quote', () => _wrap('> ', '')),
                  _format(Icons.link, 'Link', () => _wrap('[', '](https://)')),
                  _format(
                    _preview ? Icons.edit_outlined : Icons.visibility_outlined,
                    _preview ? 'Edit' : 'Preview',
                    () => setState(() => _preview = !_preview),
                  ),
                ],
              ),
            ),
          if (_preview)
            Container(
              key: const Key('markdown-preview'),
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 180),
              padding: const EdgeInsets.all(12),
              child: SingleChildScrollView(
                child: ChatMarkdown(
                  text: _textController.text,
                  color: const Color(0xFFECECEC),
                ),
              ),
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (!_editing &&
                  (widget.onSendAttachment != null ||
                      widget.onSendBatch != null))
                IconButton(
                  key: const Key('attach-message'),
                  tooltip: 'Attach',
                  icon: const Icon(Icons.add_circle_outline),
                  onPressed: _sending || _picking
                      ? null
                      : _openAttachmentPicker,
                ),
              IconButton(
                key: const Key('markdown-tools'),
                tooltip: 'Markdown',
                onPressed: _sending
                    ? null
                    : () => setState(() => _formatting = !_formatting),
                icon: Icon(
                  Icons.text_format,
                  color: _formatting ? const Color(0xFF9AE585) : null,
                ),
              ),
              Expanded(
                child: Focus(
                  canRequestFocus: false,
                  onKeyEvent: _handleInputKey,
                  child: TextField(
                    key: widget.inputKey,
                    controller: _textController,
                    focusNode: _focus,
                    minLines: 1,
                    maxLines: 5,
                    keyboardType: TextInputType.multiline,
                    textInputAction: TextInputAction.newline,
                    onChanged: (_) {
                      if (_preview) setState(() {});
                    },
                    inputFormatters: [_keepDraftWhileSending],
                    decoration: const InputDecoration(
                      hintText: 'Type a message',
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              TextFieldTapRegion(
                child: IconButton.filled(
                  key: widget.sendKey,
                  onPressed: _sending || _picking ? null : _submit,
                  tooltip: _editing
                      ? 'Save edit'
                      : _isNativeDesktop
                      ? 'Send (Enter)'
                      : 'Send (Ctrl+Enter)',
                  style: IconButton.styleFrom(
                    backgroundColor: const Color(0xFF9AE585),
                    foregroundColor: const Color(0xFF0B0B0B),
                  ),
                  icon: _sending
                      ? const SizedBox.square(
                          key: Key('send-progress'),
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          _editing ? Icons.check : Icons.arrow_upward_rounded,
                        ),
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );
  Widget _format(IconData icon, String label, VoidCallback tap) => IconButton(
    tooltip: label,
    onPressed: _sending ? null : tap,
    icon: Icon(icon, size: 20),
  );
}

IconData attachmentIcon(String kind) => switch (kind) {
  'image' => Icons.image_outlined,
  'audio' => Icons.audio_file_outlined,
  'video' => Icons.movie_outlined,
  _ => Icons.insert_drive_file_outlined,
};
