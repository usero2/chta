import 'dart:async';

import 'package:flutter/material.dart';
import 'package:scroll_to_index/scroll_to_index.dart';

class ReplyMessageAnchorKey extends ValueKey<String> {
  const ReplyMessageAnchorKey(super.value);
}

class ReplyMessageList extends StatefulWidget {
  const ReplyMessageList({
    super.key,
    required this.storageId,
    required this.rows,
    required this.itemBuilder,
    required this.padding,
    this.reverse = false,
  });

  final String storageId;
  // A row can contain several messages when it displays a media album.
  final List<List<String>> rows;
  final Widget Function(BuildContext, int, ValueChanged<String>) itemBuilder;
  final EdgeInsets padding;
  final bool reverse;

  @override
  State<ReplyMessageList> createState() => _ReplyMessageListState();
}

class _ReplyMessageListState extends State<ReplyMessageList> {
  final _scroll = AutoScrollController();
  bool _jumping = false;
  String? _highlighted;
  Timer? _clearHighlight;

  @override
  void dispose() {
    _clearHighlight?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  int _indexOf(String id) => widget.rows.indexWhere((ids) => ids.contains(id));

  Future<void> _jumpTo(String id) async {
    if (_jumping || !_scroll.hasClients) return;
    final index = _indexOf(id);
    if (index < 0) return;
    _jumping = true;
    try {
      await _scroll.scrollToIndex(
        index,
        preferPosition: AutoScrollPosition.middle,
      );
      if (!mounted || !_scroll.hasClients) return;
      final current = _indexOf(id);
      if (current < 0) return;
      if (current != index) {
        await _scroll.scrollToIndex(
          current,
          preferPosition: AutoScrollPosition.middle,
        );
      }
      if (!mounted || _indexOf(id) != current) return;
      final row = _scroll.tagMap[current]?.context;
      Element? anchor;
      void findAnchor(Element element) {
        if (element.widget.key == ReplyMessageAnchorKey(id)) {
          anchor = element;
        } else if (anchor == null) {
          element.visitChildElements(findAnchor);
        }
      }

      row?.visitChildElements(findAnchor);
      if (anchor case final target?) {
        await Scrollable.ensureVisible(
          target,
          alignment: .5,
          duration: const Duration(milliseconds: 140),
        );
      }
      if (mounted && _indexOf(id) == current) {
        _clearHighlight?.cancel();
        setState(() => _highlighted = id);
        _clearHighlight = Timer(const Duration(milliseconds: 1400), () {
          setState(() => _highlighted = null);
        });
      }
    } finally {
      _jumping = false;
    }
  }

  @override
  Widget build(BuildContext context) => ListView.builder(
    key: PageStorageKey(widget.storageId),
    controller: _scroll,
    reverse: widget.reverse,
    padding: widget.padding,
    itemCount: widget.rows.length,
    findChildIndexCallback: (key) {
      final id = (key as ValueKey<String?>).value;
      final index = widget.rows.indexWhere((row) => row.firstOrNull == id);
      return index < 0 ? null : index;
    },
    itemBuilder: (context, index) => AutoScrollTag(
      key: ValueKey<String?>(widget.rows[index].firstOrNull),
      controller: _scroll,
      index: index,
      child: Semantics(
        selected: widget.rows[index].contains(_highlighted) ? true : null,
        child: ColoredBox(
          color: widget.rows[index].contains(_highlighted)
              ? Theme.of(context).colorScheme.primary.withValues(alpha: .16)
              : Colors.transparent,
          child: widget.itemBuilder(
            context,
            index,
            (id) => unawaited(_jumpTo(id)),
          ),
        ),
      ),
    ),
  );
}
