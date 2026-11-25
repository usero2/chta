import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../account/account_models.dart';
import '../notifications/incoming_notifications.dart';
import '../notifications/notification_settings_tile.dart';
import '../chat/cache_policy.dart';
import '../chat/widgets/cache_settings_tile.dart';
import '../courier/courier_service.dart';
import '../delivery/courier_settings_tile.dart';
import '../runtime/app_runtime.dart';
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
    this.cachePolicy,
    this.courier,
    super.key,
  });

  final ProfileController controller;
  final IdentityView identity;
  final Future<void> Function()? onSwitchIdentity;
  final bool? pinLockEnabled;
  final Future<void> Function(bool)? onPinLockChanged;
  final Future<void> Function()? onLockApp;
  final IncomingNotifications? notifications;
  final CachePolicy? cachePolicy;
  final CourierService? courier;

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

  Future<void> _openPrivacyPage(String path) async {
    final url = Uri.https('chta.app', path);
    try {
      if (await launchUrl(url, mode: LaunchMode.externalApplication)) return;
    } catch (_) {
      // Show the address if a browser cannot open it.
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('Open $url in your browser.')));
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
          if (AppRuntime.instance case final runtime?)
            AnimatedBuilder(
              animation: runtime,
              builder: (context, _) => Column(
                children: [
                  SwitchListTile.adaptive(
                    key: const Key('profile-background-reception'),
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Keep receiving in background'),
                    subtitle: Text(
                      runtime.error ??
                          (runtime.running
                              ? (runtime.notificationVisible
                                    ? (runtime.showLockAction &&
                                              !kIsWeb &&
                                              defaultTargetPlatform ==
                                                  TargetPlatform.android
                                          ? 'On · Lock app to stop'
                                          : 'On')
                                    : 'On · Enable the background notification in system settings')
                              : 'Off'),
                    ),
                    value: runtime.enabled,
                    onChanged: saving
                        ? null
                        : (value) => _run(() async {
                            if (value && !runtime.notificationVisible) {
                              await widget.notifications?.requestPermissions();
                            }
                            await runtime.setEnabled(value);
                          }),
                  ),
                  if (!kIsWeb &&
                      defaultTargetPlatform == TargetPlatform.android)
                    SwitchListTile.adaptive(
                      key: const Key('profile-background-lock-action'),
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Show Lock app in notification'),
                      value: runtime.showLockAction,
                      onChanged: saving
                          ? null
                          : (value) =>
                                _run(() => runtime.setShowLockAction(value)),
                    ),
                ],
              ),
            ),
          if (widget.notifications != null)
            NotificationSettingsTile(
              notifications: widget.notifications!,
              enabled: !saving,
            ),
          if (widget.cachePolicy case final policy?)
            CacheSettingsTile(policy: policy, enabled: !saving),
          if (widget.courier case final courier?)
            CourierSettingsTile(service: courier),
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
          ListTile(
            key: const Key('profile-privacy-policy'),
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.privacy_tip_outlined),
            title: const Text('Privacy Policy'),
            trailing: const Icon(Icons.open_in_new),
            onTap: saving ? null : () => _openPrivacyPage('/privacy'),
          ),
          ListTile(
            key: const Key('profile-delete-identity'),
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.person_remove_outlined),
            title: const Text('Request identity deletion'),
            trailing: const Icon(Icons.open_in_new),
            onTap: saving ? null : () => _openPrivacyPage('/delete-identity'),
          ),
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
