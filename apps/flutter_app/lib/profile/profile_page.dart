import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../account/account_models.dart';
import '../notifications/incoming_notifications.dart';
import '../notifications/notification_settings_tile.dart';
import 'profile_controller.dart';
import 'profile_store.dart';

class ProfilePage extends StatefulWidget {
  const ProfilePage({
    required this.controller,
    required this.identity,
    this.onSwitchIdentity,
    this.pinLockEnabled,
    this.onPinLockChanged,
    this.onLockApp,
    this.notifications,
    super.key,
  });

  final ProfileController controller;
  final IdentityView identity;
  final Future<void> Function()? onSwitchIdentity;
  final bool? pinLockEnabled;
  final Future<void> Function(bool)? onPinLockChanged;
  final Future<void> Function()? onLockApp;
  final IncomingNotifications? notifications;

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  late final Future<PackageInfo> packageInfo = PackageInfo.fromPlatform();
  late final TextEditingController name = TextEditingController(
    text: widget.controller.name,
  );
  bool saving = false;
  String? error;

  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      saving = true;
      error = null;
    });
    try {
      await action();
    } catch (caught) {
      if (mounted) setState(() => error = '$caught');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Profile')),
    body: AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Center(
            child: CircleAvatar(
              key: const Key('profile-avatar'),
              radius: 64,
              backgroundImage: widget.controller.avatar == null
                  ? null
                  : MemoryImage(widget.controller.avatar!),
              child: widget.controller.avatar == null
                  ? Text(
                      (name.text.trim().isEmpty ? '?' : name.text.trim()[0])
                          .toUpperCase(),
                      style: const TextStyle(fontSize: 42),
                    )
                  : null,
            ),
          ),
          const SizedBox(height: 16),
          Center(
            child: Wrap(
              spacing: 8,
              children: [
                OutlinedButton.icon(
                  key: const Key('choose-profile-image'),
                  onPressed: saving
                      ? null
                      : () => _run(widget.controller.chooseAvatar),
                  icon: const Icon(Icons.image_outlined),
                  label: const Text('Choose image'),
                ),
                if (widget.controller.avatar != null)
                  TextButton.icon(
                    onPressed: saving
                        ? null
                        : () => _run(widget.controller.removeAvatar),
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Remove'),
                  ),
              ],
            ),
          ),
          const Center(
            child: Tooltip(
              message: 'Saved as a 256×256 JPEG, up to 256 KB.',
              child: Text('PNG, JPEG, WebP · up to 10 MB'),
            ),
          ),
          const SizedBox(height: 28),
          TextField(
            key: const Key('profile-name'),
            controller: name,
            maxLength: maxProfileNameCharacters,
            decoration: const InputDecoration(
              labelText: 'Display name',
              hintText: 'Name shown to friends',
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            key: const Key('save-profile'),
            onPressed: saving
                ? null
                : () => _run(() => widget.controller.saveName(name.text)),
            icon: const Icon(Icons.save_outlined),
            label: const Text('Save profile'),
          ),
          if (saving)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: LinearProgressIndicator(),
            ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                error!,
                style: const TextStyle(color: Colors.redAccent),
              ),
            ),
          const Divider(height: 40),
          if (widget.notifications != null)
            NotificationSettingsTile(notifications: widget.notifications!),
          if (widget.pinLockEnabled != null &&
              widget.onPinLockChanged != null) ...[
            SwitchListTile.adaptive(
              key: const Key('profile-pin-lock'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Lock PIN'),
              subtitle: Text(widget.pinLockEnabled! ? 'On' : 'Off'),
              value: widget.pinLockEnabled!,
              onChanged: saving
                  ? null
                  : (value) => _run(() => widget.onPinLockChanged!(value)),
            ),
            const SizedBox(height: 12),
          ],
          if (widget.onLockApp != null) ...[
            OutlinedButton.icon(
              key: const Key('lock-app'),
              onPressed: saving ? null : () => _run(widget.onLockApp!),
              icon: const Icon(Icons.lock_outline),
              label: const Text('Lock app'),
            ),
            const SizedBox(height: 20),
          ],
          if (widget.onSwitchIdentity != null) ...[
            OutlinedButton.icon(
              key: const Key('switch-identity'),
              onPressed: saving ? null : () => _run(widget.onSwitchIdentity!),
              icon: const Icon(Icons.switch_account_outlined),
              label: const Text('Switch identity'),
            ),
            const SizedBox(height: 20),
          ],
          const Text(
            'Identity',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          SelectableText(widget.identity.id),
          const SizedBox(height: 8),
          const Text('Only a thumbnail is shared with friends.'),
          const Divider(height: 40),
          FutureBuilder<PackageInfo>(
            future: packageInfo,
            builder: (context, snapshot) {
              final info = snapshot.data;
              final version = info?.version.trim() ?? '';
              final build = info?.buildNumber.trim() ?? '';
              final label = version.isNotEmpty
                  ? 'Version $version${build.isEmpty ? '' : ' ($build)'}'
                  : snapshot.connectionState == ConnectionState.waiting
                  ? 'Version …'
                  : 'Version unavailable';
              return SelectableText(
                label,
                key: const Key('profile-app-version'),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              );
            },
          ),
        ],
      ),
    ),
  );
}
