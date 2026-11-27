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
  final _highlighted = ValueNotifier<String?>(null);
  final _indices = <String, int>{};
  final _childIndices = <String?, int>{};
  Timer? _clearHighlight;

  @override
  void initState() {
    super.initState();
    _indexRows();
  }

  @override
  void didUpdateWidget(covariant ReplyMessageList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.rows, widget.rows)) _indexRows();
  }

  void _indexRows() {
    _indices.clear();
    _childIndices.clear();
    for (var i = 0; i < widget.rows.length; i++) {
      final ids = widget.rows[i];
      _childIndices[ids.firstOrNull] = i;
      for (final id in ids) {
        _indices[id] = i;
      }
    }
  }

  @override
  void dispose() {
    _clearHighlight?.cancel();
    _highlighted.dispose();
    _scroll.dispose();
    super.dispose();
  }

  BuildContext? _rowAt(int index) => _scroll.tagMap[index]?.context;

  Future<void> _jumpTo(String id) async {
    final index = _indices[id];
    if (_jumping || !_scroll.hasClients || index == null) return;
    _jumping = true;
    try {
      final alreadyBuilt = _rowAt(index)?.mounted == true;
      if (!alreadyBuilt) {
        await _scroll.scrollToIndex(
          index,
          preferPosition: AutoScrollPosition.middle,
        );
      }
      if (!mounted || !_scroll.hasClients) return;
      final current = _indices[id];
      if (current == null) return;
      if (current != index) {
        await _scroll.scrollToIndex(
          current,
          preferPosition: AutoScrollPosition.middle,
        );
      }
      if (!mounted || _indices[id] != current) return;
      final row = _rowAt(current);
      if (row == null || !row.mounted) return;
      Element? anchor;
      void findAnchor(Element element) {
        if (element.widget.key == ReplyMessageAnchorKey(id)) {
          anchor = element;
        } else if (anchor == null) {
          element.visitChildElements(findAnchor);
        }
      }

      row.visitChildElements(findAnchor);
      if (anchor != null || alreadyBuilt && current == index) {
        await Scrollable.ensureVisible(
          anchor ?? row,
          alignment: .5,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
        );
      }
      if (mounted && _indices[id] == current) {
        _clearHighlight?.cancel();
        _highlighted.value = id;
        _clearHighlight = Timer(const Duration(milliseconds: 1400), () {
          _highlighted.value = null;
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
    findChildIndexCallback: (key) =>
        _childIndices[(key as ValueKey<String?>).value],
    itemBuilder: (context, index) {
      final ids = widget.rows[index];
      return AutoScrollTag(
        key: ValueKey<String?>(ids.firstOrNull),
        controller: _scroll,
        index: index,
        child: ValueListenableBuilder<String?>(
          valueListenable: _highlighted,
          child: widget.itemBuilder(
            context,
            index,
            (id) => unawaited(_jumpTo(id)),
          ),
          builder: (context, highlighted, child) {
            final selected = ids.contains(highlighted);
            return Semantics(
              selected: selected ? true : null,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  color: selected
                      ? Theme.of(context).colorScheme.primary
                            .withValues(alpha: .10)
                      : Colors.transparent,
                ),
                child: child,
              ),
            );
          },
        ),
      );
    },
  );
}
