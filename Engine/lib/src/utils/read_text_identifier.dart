import 'dart:convert';

const int _fnvOffsetBasis = 1469598103934665603;
const int _fnvPrime = 1099511628211;
const int _positiveInt64Mask = 0x7fffffffffffffff;

/// Stable identifier used by current read-state records.
///
/// It intentionally excludes the global script index so story insertions and
/// deletions do not make an already-read line appear unread.
int stableReadContentHash(String? speaker, String dialogue) {
  return _fnv1a63('content-v1\u0000${speaker ?? ''}\u0000$dialogue');
}

/// Stable identifier used by read-state files created before content hashes
/// were introduced. Keep this exact format for compatibility.
int stableIndexedReadHash(String? speaker, String dialogue, int scriptIndex) {
  return _fnv1a63('${speaker ?? ''}|$dialogue|$scriptIndex');
}

bool containsLegacyIndexedReadHashNear({
  required Set<int> hashes,
  required String? speaker,
  required String dialogue,
  required int currentScriptIndex,
  required int radius,
}) {
  final safeRadius = radius < 0 ? 0 : radius;
  final firstIndex = currentScriptIndex > safeRadius
      ? currentScriptIndex - safeRadius
      : 0;
  final lastIndex = currentScriptIndex + safeRadius;
  for (
    var candidateIndex = firstIndex;
    candidateIndex <= lastIndex;
    candidateIndex++
  ) {
    if (hashes.contains(
      stableIndexedReadHash(speaker, dialogue, candidateIndex),
    )) {
      return true;
    }
  }
  return false;
}

int _fnv1a63(String value) {
  var hash = _fnvOffsetBasis;
  for (final byte in utf8.encode(value)) {
    hash ^= byte;
    hash = (hash * _fnvPrime) & _positiveInt64Mask;
  }
  return hash;
}
