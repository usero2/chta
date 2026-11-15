import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../attachment_files.dart';
import '../attachment_media_source.dart';
import '../chat_attachment.dart';
import '../media_item.dart';

class MediaViewer extends StatefulWidget {
  const MediaViewer({super.key, required this.items, this.initialIndex = 0});
  final List<MediaItem> items;
  final int initialIndex;
  @override
  State<MediaViewer> createState() => _MediaViewerState();
}

class _MediaViewerState extends State<MediaViewer> {
  late final PageController _pages = PageController(
    initialPage: widget.initialIndex,
  );
  late int _index = widget.initialIndex;
  final _files = <int, Future<ChatAttachment>>{};
  Future<ChatAttachment> _load(int index) =>
      _files.putIfAbsent(index, widget.items[index].loadFile);
  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    try {
      await saveChatAttachment(await _load(_index));
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not save file: $error')));
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    extendBodyBehindAppBar: true,
    appBar: AppBar(
      backgroundColor: Colors.transparent,
      foregroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      flexibleSpace: const DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.black87, Colors.transparent],
          ),
        ),
      ),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.items[_index].name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          if (widget.items.length > 1)
            Text(
              '${_index + 1} / ${widget.items.length}',
              style: const TextStyle(fontSize: 12),
            ),
        ],
      ),
      actions: [
        IconButton(
          onPressed: _save,
          tooltip: 'Save copy',
          icon: const Icon(Icons.save_alt),
        ),
      ],
    ),
    body: PageView.builder(
      controller: _pages,
      itemCount: widget.items.length,
      onPageChanged: (index) => setState(() => _index = index),
      itemBuilder: (context, index) => FutureBuilder<ChatAttachment>(
        future: _load(index),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: TextButton.icon(
                onPressed: () => setState(() => _files.remove(index)),
                icon: const Icon(Icons.refresh),
                label: const Text('Retry cached file'),
              ),
            );
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final file = snapshot.data!;
          if (file.isStreamed) {
            return Center(
              child: Text(
                'Save ${file.name} to open it.',
                style: const TextStyle(color: Colors.white),
              ),
            );
          }
          if (file.kind == 'image') {
            return Center(
              child: InteractiveViewer(
                minScale: 0.5,
                maxScale: 5,
                child: Image.memory(
                  file.bytes,
                  errorBuilder: (_, _, _) =>
                      const Text('Cannot display this image.'),
                ),
              ),
            );
          }
          return index == _index
              ? AttachmentPlayback(attachment: file)
              : const Center(child: Icon(Icons.play_circle_outline));
        },
      ),
    ),
  );
}

class AttachmentPlayback extends StatefulWidget {
  const AttachmentPlayback({super.key, required this.attachment});
  final ChatAttachment attachment;
  @override
  State<AttachmentPlayback> createState() => AttachmentPlaybackState();
}

class AttachmentPlaybackState extends State<AttachmentPlayback> {
  Player? _player;
  VideoController? _controller;
  AttachmentMediaSource? _source;
  StreamSubscription<String>? _errors;
  bool _error = false;
  late final Future<void> _initialization;
  @override
  void initState() {
    super.initState();
    _initialization = _open();
  }

  Future<void> _open() async {
    try {
      _source = await createAttachmentMediaSource(widget.attachment);
      if (!mounted) return;
      MediaKit.ensureInitialized();
      final player = Player();
      _player = player;
      _controller = VideoController(player);
      _errors = player.stream.error.listen((error) {
        if (mounted && error.isNotEmpty) setState(() => _error = true);
      });
      await player.open(Media(_source!.uri), play: false);
      if (mounted) setState(() {});
    } catch (_) {
      if (mounted) setState(() => _error = true);
    }
  }

  @override
  void dispose() {
    unawaited(_cleanup());
    super.dispose();
  }

  Future<void> _cleanup() async {
    await _initialization;
    try {
      await _errors?.cancel();
    } finally {
      try {
        await _player?.dispose();
      } finally {
        await _source?.dispose();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error) {
      return const Center(child: Text('Cannot play this file.'));
    }
    if (_controller == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final controls = AttachmentMediaControls(
      playing: _player!.stream.playing,
      position: _player!.stream.position,
      duration: _player!.stream.duration,
      initialPlaying: _player!.state.playing,
      initialPosition: _player!.state.position,
      initialDuration: _player!.state.duration,
      onToggle: () => _player!.playOrPause(),
      onSeek: (value) => _player!.seek(value),
    );
    if (widget.attachment.kind != 'video') {
      return Center(child: controls);
    }
    return VideoPlaybackViewport(
      videoBuilder: (fit) =>
          Video(controller: _controller!, fit: fit, controls: NoVideoControls),
      controls: controls,
    );
  }
}

/// Controls overlay the full video viewport rather than reducing its height.
class VideoPlaybackViewport extends StatefulWidget {
  const VideoPlaybackViewport({
    super.key,
    required this.videoBuilder,
    required this.controls,
  });
  final Widget Function(BoxFit) videoBuilder;
  final Widget controls;
  @override
  State<VideoPlaybackViewport> createState() => _VideoPlaybackViewportState();
}

class _VideoPlaybackViewportState extends State<VideoPlaybackViewport> {
  bool _fill = false, _controlsVisible = true;
  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _controlsVisible = !_controlsVisible),
        child: widget.videoBuilder(_fill ? BoxFit.cover : BoxFit.contain),
      ),
      if (_controlsVisible)
        Align(
          alignment: Alignment.bottomCenter,
          child: DecoratedBox(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.transparent, Colors.black87],
              ),
            ),
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(child: widget.controls),
                    IconButton(
                      onPressed: () => setState(() => _fill = !_fill),
                      tooltip: _fill ? 'Fit video' : 'Fill screen',
                      icon: Icon(
                        _fill ? Icons.fit_screen : Icons.crop_free,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
    ],
  );
}

/// Accessible controls shared by audio and video previews.
class AttachmentMediaControls extends StatelessWidget {
  const AttachmentMediaControls({
    super.key,
    required this.playing,
    required this.position,
    required this.duration,
    required this.onToggle,
    required this.onSeek,
    this.initialPlaying = false,
    this.initialPosition = Duration.zero,
    this.initialDuration = Duration.zero,
  });
  final Stream<bool> playing;
  final Stream<Duration> position;
  final Stream<Duration> duration;
  final VoidCallback onToggle;
  final ValueChanged<Duration> onSeek;
  final bool initialPlaying;
  final Duration initialPosition;
  final Duration initialDuration;

  @override
  Widget build(BuildContext context) => StreamBuilder<bool>(
    stream: playing,
    initialData: initialPlaying,
    builder: (context, playingSnapshot) => StreamBuilder<Duration>(
      stream: duration,
      initialData: initialDuration,
      builder: (context, durationSnapshot) => StreamBuilder<Duration>(
        stream: position,
        initialData: initialPosition,
        builder: (context, positionSnapshot) {
          final total = durationSnapshot.data ?? Duration.zero;
          final current = positionSnapshot.data ?? Duration.zero;
          final maxMs = total.inMilliseconds.clamp(0, 0x7fffffff).toDouble();
          final currentMs = current.inMilliseconds
              .clamp(0, maxMs.toInt())
              .toDouble();
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: playingSnapshot.data == true ? 'Pause' : 'Play',
                onPressed: onToggle,
                icon: Icon(
                  playingSnapshot.data == true ? Icons.pause : Icons.play_arrow,
                  size: 48,
                ),
              ),
              Text('${_durationText(current)} / ${_durationText(total)}'),
              Slider(
                value: currentMs,
                min: 0,
                max: maxMs > 0 ? maxMs : 1,
                label: _durationText(current),
                onChanged: maxMs > 0
                    ? (value) => onSeek(Duration(milliseconds: value.round()))
                    : null,
              ),
            ],
          );
        },
      ),
    ),
  );
}

String _durationText(Duration duration) {
  final seconds = duration.inSeconds.clamp(0, 0x7fffffff);
  final hours = seconds ~/ 3600;
  final minutes = (seconds ~/ 60) % 60;
  final remainder = (seconds % 60).toString().padLeft(2, '0');
  return hours > 0
      ? '$hours:${minutes.toString().padLeft(2, '0')}:$remainder'
      : '$minutes:$remainder';
}
