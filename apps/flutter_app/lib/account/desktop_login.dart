import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../profile/profile_avatar.dart';
import '../profile/profile_controller.dart';
import 'account_controller.dart';

String? validateDesktopPin(String? value) =>
    RegExp(r'^\d{6,12}$').hasMatch(value ?? '') ? null : 'Use 6 to 12 digits.';

class DesktopIdentityPicker extends StatefulWidget {
  const DesktopIdentityPicker({required this.controller, super.key});
  final AccountController controller;
  @override
  State<DesktopIdentityPicker> createState() => _DesktopIdentityPickerState();
}

class _DesktopIdentityPickerState extends State<DesktopIdentityPicker> {
  final pin = TextEditingController();
  final form = GlobalKey<FormState>();
  String? selected;
  @override
  void initState() {
    super.initState();
    selected = widget.controller.savedIdentities.firstOrNull?.identityId;
  }

  @override
  void dispose() {
    pin.clear();
    pin.dispose();
    super.dispose();
  }

  Future<void> _unlock() async {
    if (selected == null || (_requiresPin && !form.currentState!.validate())) {
      return;
    }
    if (await widget.controller.unlock(selected!, pin.text) && mounted) {
      pin.clear();
    }
  }

  bool get _requiresPin =>
      widget.controller.savedIdentities
          .where((entry) => entry.identityId == selected)
          .firstOrNull
          ?.requiresPin ??
      true;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620),
        child: Form(
          key: form,
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(32),
            children: [
              const Text(
                'chta',
                style: TextStyle(fontSize: 38, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              const Text(
                'Choose an identity',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 20),
              if (widget.controller.savedIdentities.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 20),
                  child: Text('No saved identities.'),
                ),
              for (final identity in widget.controller.savedIdentities)
                Card(
                  child: ListTile(
                    key: Key('saved-identity-${identity.identityId}'),
                    selected: selected == identity.identityId,
                    leading: ProfileAvatar(
                      name: identity.displayName,
                      avatarBase64: identity.avatarBase64,
                    ),
                    title: Text(
                      identity.displayName.isEmpty
                          ? 'Saved identity'
                          : identity.displayName,
                    ),
                    subtitle: Text(
                      identity.identityId,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: Icon(
                      selected == identity.identityId
                          ? Icons.radio_button_checked
                          : Icons.radio_button_off,
                    ),
                    onTap: widget.controller.working
                        ? null
                        : () => setState(() {
                            selected = identity.identityId;
                            pin.clear();
                            widget.controller.error = null;
                          }),
                  ),
                ),
              if (selected != null) ...[
                const SizedBox(height: 20),
                if (_requiresPin)
                  TextFormField(
                    key: const Key('login-pin'),
                    controller: pin,
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    keyboardType: TextInputType.number,
                    maxLength: 12,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    validator: validateDesktopPin,
                    decoration: const InputDecoration(labelText: 'PIN'),
                    onFieldSubmitted: (_) => _unlock(),
                  ),
                if (widget.controller.errorMessage != null)
                  Text(
                    widget.controller.errorMessage!,
                    key: const Key('pin-login-error'),
                    style: const TextStyle(color: Colors.redAccent),
                  ),
                FilledButton.icon(
                  key: const Key('unlock-saved-identity'),
                  onPressed: widget.controller.working ? null : _unlock,
                  icon: const Icon(Icons.lock_open),
                  label: Text(
                    widget.controller.working
                        ? 'Unlocking…'
                        : _requiresPin
                        ? 'Unlock'
                        : 'Continue',
                  ),
                ),
                const SizedBox(height: 8),
                if (_requiresPin)
                  TextButton(
                    onPressed: widget.controller.working
                        ? null
                        : widget.controller.beginRestore,
                    child: const Text('Forgot PIN?'),
                  ),
              ],
              const Divider(height: 32),
              OutlinedButton.icon(
                key: const Key('restore-another-identity'),
                onPressed: widget.controller.working
                    ? null
                    : widget.controller.beginRestore,
                icon: const Icon(Icons.restore),
                label: const Text('Restore another identity'),
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                key: const Key('create-another-identity'),
                onPressed: widget.controller.working
                    ? null
                    : widget.controller.createIdentity,
                icon: const Icon(Icons.person_add_alt),
                label: const Text('Create new identity'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class DesktopPinSetup extends StatefulWidget {
  const DesktopPinSetup({
    required this.controller,
    required this.profile,
    super.key,
  });
  final AccountController controller;
  final ProfileController profile;
  @override
  State<DesktopPinSetup> createState() => _DesktopPinSetupState();
}

class _DesktopPinSetupState extends State<DesktopPinSetup> {
  final form = GlobalKey<FormState>();
  final pin = TextEditingController();
  final confirmation = TextEditingController();
  late final name = TextEditingController(
    text: widget.profile.name.isEmpty
        ? 'Identity ${widget.controller.identity!.id.substring(widget.controller.identity!.id.length - 8)}'
        : widget.profile.name,
  );
  @override
  void dispose() {
    pin.clear();
    confirmation.clear();
    pin.dispose();
    confirmation.dispose();
    name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!form.currentState!.validate()) return;
    await widget.controller.savePin(
      pin.text,
      name.text.trim(),
      widget.profile.contactAvatar,
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620),
        child: Form(
          key: form,
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(32),
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: widget.controller.working
                      ? null
                      : widget.controller.cancelIdentityCreation,
                  icon: const Icon(Icons.arrow_back),
                  label: const Text('Back'),
                ),
              ),
              const Text(
                'Set a PIN',
                style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              const Text(
                'Use this PIN to unlock. Keep your recovery phrase safe.',
              ),
              const SizedBox(height: 20),
              Center(
                child: ProfileAvatar(
                  name: name.text,
                  bytes: widget.profile.avatar,
                  radius: 32,
                ),
              ),
              const SizedBox(height: 20),
              TextFormField(
                key: const Key('identity-name'),
                controller: name,
                maxLength: 64,
                validator: (value) => value == null || value.trim().isEmpty
                    ? 'Enter a name for this identity.'
                    : null,
                decoration: const InputDecoration(labelText: 'Profile name'),
              ),
              TextFormField(
                key: const Key('setup-pin'),
                controller: pin,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                maxLength: 12,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                validator: validateDesktopPin,
                decoration: const InputDecoration(
                  labelText: 'PIN (6 to 12 digits)',
                ),
              ),
              const SizedBox(height: 8),
              TextFormField(
                key: const Key('confirm-pin'),
                controller: confirmation,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                maxLength: 12,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                validator: (value) => value == pin.text
                    ? validateDesktopPin(value)
                    : 'PINs do not match.',
                decoration: const InputDecoration(labelText: 'Confirm PIN'),
                onFieldSubmitted: (_) => _save(),
              ),
              if (widget.controller.errorMessage != null)
                Text(
                  widget.controller.errorMessage!,
                  style: const TextStyle(color: Colors.redAccent),
                ),
              const SizedBox(height: 12),
              FilledButton.icon(
                key: const Key('save-identity-pin'),
                onPressed: widget.controller.working ? null : _save,
                icon: const Icon(Icons.lock_outline),
                label: Text(
                  widget.controller.working ? 'Saving…' : 'Save and continue',
                ),
              ),
              const SizedBox(height: 20),
              SelectableText(
                widget.controller.identity!.id,
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
