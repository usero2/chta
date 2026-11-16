import 'package:flutter/foundation.dart';

abstract interface class ContactRequestTransport implements Listenable {
  bool get registered;
  Stream<Map<String, Object?>> get contactRequests;
  Future<void> sendContactRequest(Map<String, Object?> envelope);
}
