import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../account/account_bridge.dart';
import '../account/contact_qr_files.dart';
import 'relay_network.dart';

/// Importing routes never adds a friend or verifies a fingerprint.
Future<List<String>> relayRoutesFromQr(
  String source,
  AccountBridge account,
) async {
  if (source.length > 16384) throw const FormatException('QR is too large.');
  final text = source.trim();
  final routes = text.startsWith('{')
      ? (await account.inspectContactCard(text)).relayUrls
      : [normalizeRelayUrl(text)];
  if (routes.isEmpty) throw const FormatException('This QR has no relay.');
  final normalized = routes.take(2).map(normalizeRelayUrl).toList();
  for (final route in normalized) {
    final url = Uri.parse(route);
    final host = url.host.replaceAll('[', '').replaceAll(']', '');
    if (url.scheme != 'wss' ||
        ['localhost', '::', '::1'].contains(host) ||
        host.startsWith('127.') ||
        host.endsWith('.localhost') ||
        host.endsWith('.local') ||
        host.endsWith('.internal')) {
      throw const FormatException('Use a public relay QR.');
    }
  }
  return normalized;
}

/// A shareable relay address and QR, kept visible as the endpoint changes.
class RelayQrRow extends StatelessWidget {
  const RelayQrRow({super.key, required this.endpoint, this.onSave});

  final String endpoint;
  final Future<void> Function()? onSave;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final qrSize = constraints.maxWidth < 400 ? 112.0 : 128.0;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            ContactQrView(
              key: const Key('relay-share-qr'),
              card: endpoint,
              size: qrSize,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  SelectableText(
                    endpoint,
                    style: const TextStyle(fontSize: 12),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        key: const Key('relay-copy-url'),
                        tooltip: 'Copy relay address',
                        onPressed: () async {
                          try {
                            await Clipboard.setData(
                              ClipboardData(text: endpoint),
                            );
                          } catch (_) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Could not copy URL.'),
                                ),
                              );
                            }
                          }
                        },
                        icon: const Icon(Icons.copy_outlined),
                      ),
                      IconButton(
                        key: const Key('relay-save-qr'),
                        tooltip: 'Save QR',
                        onPressed: () async {
                          try {
                            if (onSave != null) {
                              await onSave!();
                            } else {
                              await saveContactQrImage(endpoint);
                            }
                          } catch (_) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Could not save QR.'),
                                ),
                              );
                            }
                          }
                        },
                        icon: const Icon(Icons.download_outlined),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    },
  );
}
