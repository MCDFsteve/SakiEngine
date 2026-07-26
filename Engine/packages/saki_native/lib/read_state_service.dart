import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';

import 'src/rust/api/read_state.dart';

Future<bool> replaceReadStateValues({
  required BigInt handle,
  required List<int> stableHashes,
  required List<int> legacyHashes,
}) {
  return readStateReplace(
    handle: handle,
    stableHashes: Int64List.fromList(stableHashes),
    legacyHashes: legacyHashes,
  );
}
