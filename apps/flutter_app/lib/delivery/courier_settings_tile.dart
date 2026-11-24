import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../courier/courier_service.dart';

class CourierSettingsTile extends StatefulWidget {
  const CourierSettingsTile({required this.service, super.key});
  final CourierService service;

  @override
  State<CourierSettingsTile> createState() => _CourierSettingsTileState();
}

class _CourierSettingsTileState extends State<CourierSettingsTile> {
  static const _mib = 1024 * 1024;
  bool _busy = false;
  String? _error;

  Future<void> _run(Future<void> Function() action) async {
    if (_busy || !widget.service.ready) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not save Courier settings');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _capacity() async {
    final service = widget.service;
    final current =
        (service.hostStore?.policy.capacityBytes ?? 1024 * _mib) ~/ _mib;
    final picked = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Courier capacity'),
        children: [
          for (final value in {
            256,
            512,
            1024,
            2048,
            4096,
            current,
          }.toList()..sort())
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, value),
              child: Text(
                '${value >= 1024 && value % 1024 == 0 ? '${value ~/ 1024} GiB' : '$value MiB'}${value == current ? ' · current' : ''}',
              ),
            ),
        ],
      ),
    );
    if (mounted && picked != null && widget.service == service) {
      await _run(() => service.setCapacityBytes(picked * _mib));
    }
  }

  Future<void> _showReport() async {
    final report = widget.service.diagnosticReport();
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delivery diagnostics'),
        content: SingleChildScrollView(child: SelectableText(report)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
          TextButton.icon(
            icon: const Icon(Icons.copy_outlined),
            label: const Text('Copy report'),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: report));
              if (ctx.mounted) Navigator.pop(ctx);
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.service,
    builder: (context, _) {
      final service = widget.service, store = service.hostStore;
      final status = !service.canHost
          ? 'Send and receive only'
          : !service.hosting
          ? 'Hosting off'
          : service.advertised
          ? 'Hosting · available'
          : 'Hosting · waiting for a relay';
      return Card(
        child: ExpansionTile(
          leading: const Icon(Icons.inventory_2_outlined),
          title: const Text('Courier'),
          subtitle: Text(status),
          children: [
            if (service.canHost)
              SwitchListTile(
                title: const Text('Host Courier'),
                value: service.hosting,
                onChanged: !service.ready || _busy
                    ? null
                    : (value) => _run(() => service.setHosting(value)),
              ),
            if (service.canHost && store != null)
              ListTile(
                title: const Text('Storage limit'),
                subtitle: Text(
                  '${(store.storedBytes / _mib).toStringAsFixed(1)} / ${store.policy.capacityBytes ~/ _mib} MiB used',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: !service.ready || _busy ? null : _capacity,
              ),
            if (_error != null)
              ListTile(
                title: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            ListTile(
              title: const Text('Delivery diagnostics'),
              trailing: const Icon(Icons.chevron_right),
              onTap: service.ready ? _showReport : null,
            ),
          ],
        ),
      );
    },
  );
}
