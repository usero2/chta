import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../groups/group_blob_bridge.dart';

class TurnInvite {
  const TurnInvite._(this.endpoint, this.token);

  final Uri endpoint;
  final String token;
  static final _dns = RegExp(
    r'^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?$',
  );

  static TurnInvite parse(String source) {
    final text = source.trim();
    final uri = text.length <= 384 ? Uri.tryParse(text) : null;
    if (uri == null ||
        uri.scheme != 'https' ||
        !_dns.hasMatch(uri.host) ||
        uri.host.length > 253 ||
        const ['.local', '.localhost', '.internal'].any(uri.host.endsWith) ||
        uri.userInfo.isNotEmpty ||
        uri.authority.contains('@') ||
        uri.port != 443 ||
        uri.path != '/ice' ||
        uri.hasQuery ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(uri.fragment)) {
      throw const FormatException('Enter a valid TURN invite link.');
    }
    return TurnInvite._(Uri.https(uri.host, '/ice'), uri.fragment);
  }

  String get stored => endpoint.replace(fragment: token).toString();
}

class TurnSettings extends ChangeNotifier {
  TurnSettings({
    required this.ownerId,
    this.store,
    http.Client? client,
    DateTime Function()? clock,
  }) : _client = client ?? http.Client(),
       _clock = clock ?? DateTime.now;

  static const _key = 'turn_invite_v1';
  static const _timeout = Duration(seconds: 4);
  final String ownerId;
  final GroupBlobBridge? store;
  final http.Client _client;
  final DateTime Function() _clock;
  TurnInvite? _invite;
  _TurnLease? _lease;
  Future<_TurnLease>? _refresh;
  DateTime? _retryAfter;
  Future<void>? _initialization;
  bool _disposed = false;
  bool _saving = false;

  String? get host => _invite?.endpoint.host;

  Future<void> initialize() => _initialization ??= _load();

  Future<void> _load() async {
    try {
      final source = await store?.loadGroupBlob(ownerId, _key);
      if (_disposed || source == null) return;
      _invite = TurnInvite.parse(source);
      notifyListeners();
    } catch (_) {
      // STUN and the existing relay routes remain available.
    }
  }

  Future<void> install(String source) async {
    await initialize();
    if (_disposed || _saving) throw StateError('TURN settings are busy.');
    final invite = TurnInvite.parse(source);
    _saving = true;
    try {
      final lease = await _request(invite);
      if (_disposed) return;
      await store?.saveGroupBlob(ownerId, _key, invite.stored);
      if (_disposed) return;
      _invite = invite;
      _lease = lease;
      _refresh = null;
      _retryAfter = null;
      notifyListeners();
    } finally {
      _saving = false;
    }
  }

  Future<void> remove() async {
    await initialize();
    if (_disposed || _saving) throw StateError('TURN settings are busy.');
    _saving = true;
    try {
      await store?.deleteGroupBlob(ownerId, _key);
      if (_disposed) return;
      _invite = null;
      _lease = null;
      _refresh = null;
      _retryAfter = null;
      notifyListeners();
    } finally {
      _saving = false;
    }
  }

  Future<List<Map<String, Object>>> iceServers() async {
    await initialize();
    final invite = _invite;
    if (_disposed || invite == null) return const [];
    final cached = _lease;
    final now = _clock();
    if (cached != null &&
        now.add(const Duration(minutes: 2)).isBefore(cached.expires)) {
      return [cached.server];
    }
    if (_retryAfter?.isAfter(now) == true) return const [];
    final refresh = _refresh ??= _request(invite);
    try {
      final lease = await refresh;
      if (_disposed || !identical(invite, _invite)) return const [];
      _lease = lease;
      return [lease.server];
    } catch (_) {
      if (!_disposed && identical(invite, _invite)) {
        _retryAfter = _clock().add(const Duration(seconds: 30));
      }
      return const [];
    } finally {
      if (identical(_refresh, refresh)) _refresh = null;
    }
  }

  Future<_TurnLease> _request(TurnInvite invite) async {
    final abort = Completer<void>();
    return _fetch(invite, abort.future).timeout(
      _timeout,
      onTimeout: () {
        abort.complete();
        throw const FormatException('TURN server timed out.');
      },
    );
  }

  Future<_TurnLease> _fetch(TurnInvite invite, Future<void> abort) async {
    final startedAt = _clock();
    final request =
        http.AbortableRequest('GET', invite.endpoint, abortTrigger: abort)
          ..followRedirects = false
          ..headers['authorization'] = 'Bearer ${invite.token}';
    final response = await _client.send(request);
    if (response.statusCode != 200) {
      final subscription = response.stream.listen((_) {});
      await subscription.cancel();
      throw FormatException(
        response.statusCode == 401 || response.statusCode == 403
            ? 'This TURN invite was declined.'
            : 'Could not reach the TURN server.',
      );
    }
    final body = <int>[];
    await for (final chunk in response.stream.timeout(_timeout)) {
      if (body.length + chunk.length > 4096) {
        throw const FormatException('Invalid TURN server response.');
      }
      body.addAll(chunk);
    }
    final value = jsonDecode(utf8.decode(body));
    if (value is! Map<String, dynamic> ||
        value['version'] != 1 ||
        value['ttl'] is! int ||
        value['ttl'] < 300 ||
        value['ttl'] > 86400 ||
        !_validCredential(value['username']) ||
        !_validCredential(value['credential'])) {
      throw const FormatException('Invalid TURN server response.');
    }
    final urls = value['urls'];
    final host = RegExp.escape(invite.endpoint.host);
    final pattern = RegExp('^turn:$host:3478\\?transport=(udp|tcp)\$');
    if (urls is! List ||
        urls.isEmpty ||
        urls.length > 2 ||
        urls.any((url) => url is! String || !pattern.hasMatch(url))) {
      throw const FormatException(
        'TURN server returned an unexpected address.',
      );
    }
    return _TurnLease({
      'urls': List<String>.unmodifiable(urls.cast<String>()),
      'username': value['username'] as String,
      'credential': value['credential'] as String,
    }, startedAt.add(Duration(seconds: value['ttl'] as int)));
  }

  static bool _validCredential(Object? value) =>
      value is String && RegExp(r'^[!-~]{1,256}$').hasMatch(value);

  @override
  void dispose() {
    _disposed = true;
    _client.close();
    super.dispose();
  }
}

class _TurnLease {
  const _TurnLease(this.server, this.expires);
  final Map<String, Object> server;
  final DateTime expires;
}
