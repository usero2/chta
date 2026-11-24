import 'dart:async';

import 'package:flutter/material.dart';

import '../cache_policy.dart';

class CacheSettingsTile extends StatefulWidget {
  const CacheSettingsTile({
    required this.policy,
    this.enabled = true,
    super.key,
  });
  final CachePolicy policy;
  final bool enabled;
  @override
  State<CacheSettingsTile> createState() => _CacheSettingsTileState();
}

class _CacheSettingsTileState extends State<CacheSettingsTile> {
  late final limit = TextEditingController(
    text: '${widget.policy.limitBytes ~/ CachePolicy.gib}',
  );
  bool _saving = false, _edited = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    if (!widget.policy.ready) {
      unawaited(
        widget.policy
            .initialize()
            .then((_) {
              if (mounted && !_edited) {
                limit.text = '${widget.policy.limitBytes ~/ CachePolicy.gib}';
              }
            })
            .catchError((Object _) {}),
      );
    }
  }

  @override
  void dispose() {
    limit.dispose();
    super.dispose();
  }

  Future<void> _apply() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final value = int.tryParse(limit.text.trim());
      if (value == null) throw const CachePolicyException('Choose 1–1024 GB.');
      await widget.policy.setLimitGiB(value);
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is CachePolicyException
              ? error.message
              : 'Could not save cache settings. Try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _retry() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.policy.initialize();
      if (mounted && !_edited) {
        limit.text = '${widget.policy.limitBytes ~/ CachePolicy.gib}';
      }
    } catch (_) {
      // The policy exposes its recoverable load error below.
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.policy,
    builder: (context, _) {
      final enabled =
          widget.enabled &&
          widget.policy.canChange &&
          widget.policy.ready &&
          !_saving;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Cache',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(
            '${(widget.policy.reservedBytes / CachePolicy.gib).toStringAsFixed(2)} / ${widget.policy.limitBytes ~/ CachePolicy.gib} GB · cached and reserved',
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              SizedBox(
                width: 140,
                child: TextField(
                  key: const Key('cache-limit'),
                  controller: limit,
                  enabled: enabled,
                  keyboardType: TextInputType.number,
                  onChanged: (_) => _edited = true,
                  decoration: const InputDecoration(labelText: 'Limit (GB)'),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton(
                key: const Key('apply-cache-limit'),
                onPressed: enabled ? _apply : null,
                child: const Text('Apply'),
              ),
            ],
          ),
          if ((_error ?? widget.policy.error) case final error?)
            Padding(padding: const EdgeInsets.only(top: 8), child: Text(error)),
          if (!widget.policy.ready && widget.policy.error != null)
            TextButton(
              onPressed: widget.enabled && widget.policy.canChange && !_saving
                  ? _retry
                  : null,
              child: const Text('Retry'),
            ),
          const Divider(height: 32),
        ],
      );
    },
  );
}
