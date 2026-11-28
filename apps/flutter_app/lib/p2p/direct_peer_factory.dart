import 'direct_peer.dart';
import 'direct_peer_webrtc.dart';

DirectPeerFactory createDirectPeerFactory({
  Future<List<Map<String, Object>>> Function()? turnServers,
}) => WebRtcDirectPeerFactory(turnServers: turnServers);
