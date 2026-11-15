import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

import 'direct_peer.dart';

/// WebRTC has no media tracks here. Only STUN is configured; TURN is absent.
class WebRtcDirectPeerFactory implements DirectPeerFactory {
  @override
  Future<DirectPeer> create() async {
    final connection = await rtc.createPeerConnection({
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
      ],
      'iceTransportPolicy': 'all',
      'sdpSemantics': 'unified-plan',
    });
    return WebRtcDirectPeer(connection);
  }
}

class WebRtcDirectPeer implements DirectPeer {
  WebRtcDirectPeer(this._connection) {
    _connection.onIceCandidate = (candidate) {
      final value = candidate.candidate;
      if (value != null && value.isNotEmpty) {
        onIceCandidate?.call(value, candidate.sdpMid, candidate.sdpMLineIndex);
      }
    };
    _connection.onDataChannel = _attachChannel;
    _connection.onConnectionState = (state) {
      if (state ==
              rtc.RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
          state == rtc.RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == rtc.RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        onReadyChanged?.call(false);
      }
    };
  }

  static const maxBufferedBytes = 256 * 1024;
  final rtc.RTCPeerConnection _connection;
  rtc.RTCDataChannel? _channel;
  bool _closed = false;
  Future<void> _sendTail = Future<void>.value();

  @override
  void Function(String candidate, String? mid, int? line)? onIceCandidate;
  @override
  void Function(String frame)? onFrame;
  @override
  void Function(bool ready)? onReadyChanged;

  void _attachChannel(rtc.RTCDataChannel channel) {
    if (_closed || _channel != null || channel.label != 'cht-file-v1') {
      unawaited(channel.close());
      return;
    }
    _channel = channel;
    channel.onDataChannelState = (state) {
      onReadyChanged?.call(state == rtc.RTCDataChannelState.RTCDataChannelOpen);
    };
    channel.onMessage = (message) {
      if (!_closed && !message.isBinary) onFrame?.call(message.text);
    };
    if (channel.state == rtc.RTCDataChannelState.RTCDataChannelOpen) {
      onReadyChanged?.call(true);
    }
  }

  @override
  Future<String> createOffer() async {
    if (_closed) throw StateError('Direct peer is closed');
    final channel = await _connection.createDataChannel(
      'cht-file-v1',
      rtc.RTCDataChannelInit(),
    );
    if (_closed) {
      await channel.close();
      throw StateError('Direct peer is closed');
    }
    _attachChannel(channel);
    final offer = await _connection.createOffer();
    await _connection.setLocalDescription(offer);
    return offer.sdp ?? '';
  }

  @override
  Future<String> createAnswer() async {
    if (_closed) throw StateError('Direct peer is closed');
    final answer = await _connection.createAnswer();
    await _connection.setLocalDescription(answer);
    return answer.sdp ?? '';
  }

  @override
  Future<void> setRemoteDescription(String type, String sdp) =>
      _connection.setRemoteDescription(rtc.RTCSessionDescription(sdp, type));

  @override
  Future<void> addIceCandidate(String candidate, String? mid, int? line) =>
      _connection.addCandidate(rtc.RTCIceCandidate(candidate, mid, line));

  @override
  Future<void> send(String frame) {
    final operation = _sendTail.then((_) => _sendOne(frame));
    _sendTail = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> _sendOne(String frame) async {
    final channel = _channel;
    if (_closed ||
        channel == null ||
        channel.state != rtc.RTCDataChannelState.RTCDataChannelOpen) {
      throw StateError('Direct data channel is closed');
    }
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (await channel.getBufferedAmount() > maxBufferedBytes) {
      if (_closed ||
          channel.state != rtc.RTCDataChannelState.RTCDataChannelOpen) {
        throw StateError('Direct data channel is closed');
      }
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException('Direct data channel backpressure');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await channel.send(rtc.RTCDataChannelMessage(frame));
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    onReadyChanged?.call(false);
    final channel = _channel;
    _channel = null;
    if (channel != null) await channel.close();
    await _connection.close();
    await _connection.dispose();
  }
}
