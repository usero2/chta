import 'package:flutter/material.dart';

import 'incoming_notifications.dart';

class NotificationSettingsTile extends StatefulWidget {
  const NotificationSettingsTile({required this.notifications, super.key});
  final IncomingNotifications notifications;
  @override
  State<NotificationSettingsTile> createState() =>
      _NotificationSettingsTileState();
}

class _NotificationSettingsTileState extends State<NotificationSettingsTile> {
  bool _requesting = false;
  bool _denied = false;

  Future<void> _enable() async {
    setState(() => _requesting = true);
    final allowed = await widget.notifications.requestPermissions();
    if (!mounted) return;
    setState(() {
      _requesting = false;
      _denied = !allowed;
    });
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.notifications,
    builder: (context, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.notifications_outlined),
          title: const Text('Notifications'),
          subtitle: Text(
            widget.notifications.enabled ? 'On' : 'Messages and files',
          ),
          trailing: widget.notifications.enabled
              ? null
              : TextButton(
                  key: const Key('enable-notifications'),
                  onPressed: _requesting ? null : _enable,
                  child: Text(_requesting ? 'Enabling…' : 'Enable'),
                ),
        ),
        if (_denied && !widget.notifications.enabled)
          const Text('Allow notifications in system settings.'),
        const SizedBox(height: 16),
      ],
    ),
  );
}
