abstract class DirectPeerFactory {
  Future<DirectPeer> create();
}

/// Data-only WebRTC peer. Callbacks belong to exactly one coordinator generation.
abstract class DirectPeer {
  set onIceCandidate(
    void Function(String candidate, String? mid, int? line)? value,
  );
  set onFrame(void Function(String frame)? value);
  set onReadyChanged(void Function(bool ready)? value);

  Future<String> createOffer();
  Future<String> createAnswer();
  Future<void> setRemoteDescription(String type, String sdp);
  Future<void> addIceCandidate(String candidate, String? mid, int? line);
  Future<void> send(String frame);
  Future<void> close();
}
