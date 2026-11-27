import 'dart:async';

import 'package:flutter/material.dart';

/// Draw a first frame before opening secure storage. A platform failure must
/// never leave Android's native splash covering the app indefinitely.
class AppBootstrap extends StatefulWidget {
  const AppBootstrap({
    required this.load,
    this.timeout = const Duration(seconds: 20),
    super.key,
  });

  final Future<Widget> Function() load;
  final Duration timeout;

  @override
  State<AppBootstrap> createState() => _AppBootstrapState();
}

class _AppBootstrapState extends State<AppBootstrap> {
  Widget? _app;
  bool _failed = false;
  int _attempt = 0;
  Future<Widget>? _pending;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final attempt = ++_attempt;
    setState(() => _failed = false);
    try {
      // A timeout does not cancel platform calls. Reuse a pending load so a
      // retry cannot race it and reset an already unlocked native session.
      final pending = _pending ??= Future.sync(widget.load);
      final app = await pending.timeout(widget.timeout);
      if (mounted && attempt == _attempt) {
        setState(() => _app = app);
      }
    } on TimeoutException {
      if (mounted && attempt == _attempt) {
        setState(() => _failed = true);
      }
    } catch (_) {
      _pending = null;
      if (mounted && attempt == _attempt) {
        setState(() => _failed = true);
      }
    }
  }

  @override
  Widget build(BuildContext context) =>
      _app ??
      MaterialApp(
        debugShowCheckedModeBanner: false,
        locale: const Locale('en', 'US'),
        theme: ThemeData.dark(),
        // No temporary Navigator: keep the browser's requested deep link intact.
        builder: (context, child) => Scaffold(
          backgroundColor: const Color(0xFF1A1A1A),
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'chta',
                    style: TextStyle(
                      fontSize: 36,
                      color: Color(0xFF9AE585),
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 24),
                  if (_failed) ...[
                    const Text(
                      'Could not open secure storage.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      key: const ValueKey('retry-startup'),
                      onPressed: _load,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Try again'),
                    ),
                  ] else ...[
                    const CircularProgressIndicator(),
                    const SizedBox(height: 16),
                    const Text('Opening chta…'),
                  ],
                ],
              ),
            ),
          ),
        ),
      );
}
