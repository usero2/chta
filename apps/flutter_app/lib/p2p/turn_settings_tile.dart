import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../account/contact_qr_files.dart';
import '../qr/qr_scanner_page.dart';
import 'turn_settings.dart';

final _guide = Uri.https('chta.app', '/wiki/turn.html');

class TurnSettingsTile extends StatelessWidget {
  const TurnSettingsTile({required this.settings, super.key});

  final TurnSettings settings;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: settings,
    builder: (context, _) => Card(
      child: ListTile(
        key: const Key('turn-settings'),
        leading: const Icon(Icons.alt_route),
        title: const Text('TURN fallback'),
        subtitle: Text(
          settings.host ?? 'Optional. Use a link from your server admin.',
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => showDialog<void>(
          context: context,
          builder: (_) => _TurnDialog(settings: settings),
        ),
      ),
    ),
  );
}

class _TurnDialog extends StatefulWidget {
  const _TurnDialog({required this.settings});

  final TurnSettings settings;

  @override
  State<_TurnDialog> createState() => _TurnDialogState();
}

class _TurnDialogState extends State<_TurnDialog> {
  final _link = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _link.dispose();
    super.dispose();
  }

  Future<void> _run(
    Future<void> Function() action, {
    bool close = false,
  }) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      if (mounted && close) Navigator.pop(context);
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is FormatException
              ? error.message
              : 'Could not update TURN settings.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _fill(Future<String?> Function() read) => _run(() async {
    final text = await read();
    if (mounted && text != null) _link.text = text.trim();
  });

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('TURN fallback'),
    scrollable: true,
    content: SizedBox(
      width: 400,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Helps connect when a direct connection is blocked.'),
          if (widget.settings.host case final host?) ...[
            const SizedBox(height: 8),
            Text(host),
            TextButton(
              onPressed: _busy
                  ? null
                  : () => _run(widget.settings.remove, close: true),
              child: const Text('Remove server'),
            ),
          ],
          const SizedBox(height: 12),
          TextField(
            key: const Key('turn-invite'),
            controller: _link,
            enabled: !_busy,
            decoration: const InputDecoration(labelText: 'TURN invite link'),
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.url,
          ),
          Wrap(
            spacing: 4,
            children: [
              TextButton(
                onPressed: _busy
                    ? null
                    : () => _fill(
                        () async =>
                            (await Clipboard.getData(Clipboard.kTextPlain))
                                ?.text,
                      ),
                child: const Text('Paste'),
              ),
              if (supportsQrCamera)
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => _fill(
                          () => scanQr(
                            context,
                            title: 'Scan TURN QR',
                            fallbackText: 'Paste the TURN link instead.',
                          ),
                        ),
                  child: const Text('Scan QR'),
                ),
              if (supportsContactQrImageImport)
                TextButton(
                  onPressed: _busy ? null : () => _fill(readContactQrImage),
                  child: const Text('Import QR'),
                ),
              TextButton(
                onPressed: () =>
                    launchUrl(_guide, mode: LaunchMode.externalApplication),
                child: const Text('Setup guide'),
              ),
            ],
          ),
          if (_error case final error?)
            Text(
              error,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          if (_busy) const LinearProgressIndicator(),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: _busy ? null : () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _busy
            ? null
            : () =>
                  _run(() => widget.settings.install(_link.text), close: true),
        child: const Text('Save'),
      ),
    ],
  );
}
