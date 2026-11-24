// Disposable Android-only entrypoint. Build with -PchtQa=true, never production.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:crypto/crypto.dart';
import 'package:cht/chat/attachment_store.dart';
import 'package:cht/account/desktop_identity_bridge.dart';
import 'package:cht/chat/peer_history.dart';
import 'package:cht/chat/peer_history_store.dart';
import 'package:cht/chat/messaging_service.dart';
import 'package:cht/core/core_bridge.dart';
import 'package:cht/core/core_bridge_factory.dart';
import 'package:cht/relay/relay_crypto_bridge.dart';
import 'package:cht/relay/relay_network.dart';
import 'package:cht/relay/default_relays.dart';
import 'package:cht/runtime/app_runtime.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const MaterialApp(
      home: Scaffold(body: Center(child: Text('chta lifecycle QA'))),
    ),
  );
  const token = String.fromEnvironment('CHTA_QA_TOKEN');
  if (!Platform.isAndroid || token.length < 32) {
    throw StateError('Disposable QA build required');
  }
  // Runtime package check prevents this entrypoint touching the production vault.
  final package = (await File(
    '/proc/self/cmdline',
  ).readAsString()).split('\u0000').first;
  if (package != 'app.cht.cht.qa') {
    throw StateError('Refusing production package');
  }
  await AppRuntime.install();
  final core = createCoreBridge();
  await (core as InitializableCoreBridge).initializePlatform();
  if (await core.hasIdentity()) {
    throw StateError('Requires an empty disposable QA vault');
  }
  final created = await core.createIdentity();
  final owner = (await core.confirmRecovery(created.mnemonic)).id;
  final history = PeerHistory(
    attachments: createAttachmentStore(bridge: core),
    store: createPeerHistoryStore(
      identityBridge: core as DesktopIdentityBridge,
    ),
  );
  await history.load(owner);
  final network = RelayNetwork(
    core as RelayCryptoBridge,
    bootstrapRelays: defaultDataRelays,
  );
  final service = MessagingService(
    ownerId: owner,
    account: core,
    network: network,
    history: history,
    ownCard: () => core.contactCard(displayName: 'Synthetic Android'),
  );
  await service.start();
  await AppRuntime.instance!.attach(
    owner,
    flush: history.flush,
    lock: () async {
      await service.close();
      await (core as DesktopIdentityBridge).lockIdentity();
    },
  );
  final marker = Random.secure().nextInt(1 << 32);
  var ticks = 0;
  Timer.periodic(const Duration(seconds: 1), (_) => ticks++);
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 48739);
  await for (final request in server) {
    if (request.headers.value('authorization') != 'Bearer $token') {
      request.response.statusCode = 403;
      await request.response.close();
      continue;
    }
    Object response;
    try {
      switch (request.uri.path) {
        case '/card':
          response = {
            'card': await core.contactCard(displayName: 'Synthetic Android'),
          };
        case '/friend':
          final input =
              jsonDecode(await utf8.decoder.bind(request).join()) as Map;
          final contact = await core.inspectContactCard(
            input['card'] as String,
          );
          await core.addContact(input['card'] as String, 'Synthetic Desktop');
          await core.markContactVerified(contact.identityId);
          await service.refreshContacts();
          response = {'ok': true};
        case '/lock':
          response = {'ok': await AppRuntime.instance!.handle('lockRequested')};
        case '/status':
          final contacts = await core.contacts();
          response = {
            'marker': marker,
            'ticks': ticks,
            'running': AppRuntime.instance!.running,
            'online': service.onlinePeers.length,
            'relays': network.online.length,
            'received': [
              for (final contact in contacts)
                for (final message in history.messagesFor(contact.identityId))
                  if (message.incoming) message.id,
            ],
            'files': [
              for (final contact in contacts)
                for (final message in history.messagesFor(contact.identityId))
                  if (message.incoming && message.hasAttachment)
                    {
                      'id': message.id,
                      'sha256': sha256
                          .convert(
                            (await history.resolveAttachment(message)).bytes,
                          )
                          .toString(),
                    },
            ],
          };
        default:
          request.response.statusCode = 404;
          response = {'error': 'not found'};
      }
    } catch (_) {
      request.response.statusCode = 500;
      response = {'error': 'QA operation failed'};
    }
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(response));
    await request.response.close();
  }
}
