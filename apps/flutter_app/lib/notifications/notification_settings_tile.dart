import 'package:flutter/material.dart';

import 'incoming_notifications.dart';

class NotificationSettingsTile extends StatefulWidget {
  const NotificationSettingsTile({
    required this.notifications,
    this.enabled = true,
    super.key,
  });
  final IncomingNotifications notifications;
  final bool enabled;
  @override
  State<NotificationSettingsTile> createState() =>
      _NotificationSettingsTileState();
}

class _NotificationSettingsTileState extends State<NotificationSettingsTile> {
  bool _requesting = false;
  bool _denied = false;
  bool _error = false;

  Future<void> _change(bool value, {bool preview = false}) async {
    setState(() {
      _requesting = true;
      _denied = false;
      _error = false;
    });
    try {
      if (preview) {
        await widget.notifications.setShowMessagePreview(value);
      } else {
        final allowed = await widget.notifications.setEnabled(value);
        if (mounted) setState(() => _denied = value && !allowed);
      }
    } catch (_) {
      if (mounted) setState(() => _error = true);
    } finally {
      if (mounted) setState(() => _requesting = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.notifications,
    builder: (context, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile.adaptive(
          key: const Key('notifications-toggle'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Notifications'),
          subtitle: Text(widget.notifications.enabled ? 'On' : 'Off'),
          value: widget.notifications.enabled,
          onChanged:
              _requesting || !widget.enabled || !widget.notifications.canChange
              ? null
              : _change,
        ),
        SwitchListTile.adaptive(
          key: const Key('notification-preview-toggle'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Show message preview'),
          value: widget.notifications.showMessagePreview,
          onChanged:
              _requesting || !widget.enabled || !widget.notifications.canChange
              ? null
              : (value) => _change(value, preview: true),
        ),
        if (_denied && !widget.notifications.enabled)
          const Text('Allow notifications in system settings.'),
        if (_error)
          const Text('Could not save notification settings. Try again.'),
        if (!_error && widget.notifications.unavailable)
          const Text('Notifications are unavailable. Try again.'),
        const SizedBox(height: 16),
      ],
    ),
  );
}
