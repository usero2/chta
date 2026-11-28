enum IceRoute { direct, turn, unknown }

final relayIceType = RegExp(r'\btyp\s+relay\b', caseSensitive: false);

bool validTurnCandidate(String value) {
  final parts = value.trim().split(RegExp(r'\s+'));
  if (parts.length < 8 ||
      parts[6] != 'typ' ||
      parts[7] != 'relay' ||
      parts.skip(8).any((part) => part.toLowerCase() == 'typ')) {
    return false;
  }
  final address = parts[4].split('.');
  if (address.length != 4 ||
      address.any(
        (part) => !RegExp(r'^(?:0|[1-9][0-9]{0,2})$').hasMatch(part),
      )) {
    return false;
  }
  final bytes = address.map(int.parse).toList();
  if (bytes.any((byte) => byte > 255)) return false;
  final [a, b, c, _] = bytes;
  return !(a == 0 ||
      a == 10 ||
      a == 127 ||
      a >= 224 ||
      a == 100 && b >= 64 && b <= 127 ||
      a == 169 && b == 254 ||
      a == 172 && b >= 16 && b <= 31 ||
      a == 192 && (b == 168 || b == 0) ||
      a == 198 && (b == 18 || b == 19 || b == 51 && c == 100) ||
      a == 203 && b == 0 && c == 113);
}

bool validTurnDescription(String value) {
  if (!relayIceType.hasMatch(value)) return true;
  return value
      .trimRight()
      .split(RegExp(r'\r?\n'))
      .every(
        (line) =>
            !relayIceType.hasMatch(line) ||
            line.startsWith('a=candidate:') &&
                validTurnCandidate(line.substring(2)),
      );
}

IceRoute selectedIceRoute(Map<String, Map<Object?, Object?>> reports) {
  Map<Object?, Object?>? pair;
  for (final report in reports.values) {
    if (report['type'] == 'transport' &&
        report['selectedCandidatePairId'] is String) {
      pair = reports[report['selectedCandidatePairId']];
      if (pair != null) break;
    }
  }
  if (pair == null) {
    final candidates = reports.values.where(
      (report) =>
          report['type'] == 'candidate-pair' &&
          report['state'] == 'succeeded' &&
          (report['selected'] == true || report['nominated'] == true),
    );
    if (candidates.length != 1) return IceRoute.unknown;
    pair = candidates.single;
  }
  final local = reports[pair['localCandidateId']]?['candidateType'];
  final remote = reports[pair['remoteCandidateId']]?['candidateType'];
  if (local == 'relay' || remote == 'relay') return IceRoute.turn;
  const directTypes = {'host', 'srflx', 'prflx'};
  return directTypes.contains(local) && directTypes.contains(remote)
      ? IceRoute.direct
      : IceRoute.unknown;
}
