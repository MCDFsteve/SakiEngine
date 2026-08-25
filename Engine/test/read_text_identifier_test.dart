import 'package:flutter_test/flutter_test.dart';
import 'package:sakiengine/src/utils/read_text_identifier.dart';

void main() {
  test('content read hash survives global script index changes', () {
    final beforeEdit = stableReadContentHash('aru', '同一句台词');
    final afterEdit = stableReadContentHash('aru', '同一句台词');

    expect(afterEdit, beforeEdit);
  });

  test('legacy indexed hash remains index-sensitive for compatibility', () {
    final beforeEdit = stableIndexedReadHash('aru', '同一句台词', 120);
    final afterEdit = stableIndexedReadHash('aru', '同一句台词', 187);

    expect(beforeEdit, 9038469596390070966);
    expect(afterEdit, isNot(beforeEdit));
  });

  test('content read hash still distinguishes speaker and dialogue', () {
    final baseline = stableReadContentHash('aru', '同一句台词');

    expect(stableReadContentHash('noe', '同一句台词'), isNot(baseline));
    expect(stableReadContentHash('aru', '另一句台词'), isNot(baseline));
  });

  test('legacy indexed records survive a bounded script index shift', () {
    final hashes = <int>{stableIndexedReadHash('aru', '旧台词', 120)};

    expect(
      containsLegacyIndexedReadHashNear(
        hashes: hashes,
        speaker: 'aru',
        dialogue: '旧台词',
        currentScriptIndex: 187,
        radius: 1024,
      ),
      isTrue,
    );
    expect(
      containsLegacyIndexedReadHashNear(
        hashes: hashes,
        speaker: 'aru',
        dialogue: '旧台词',
        currentScriptIndex: 187,
        radius: 32,
      ),
      isFalse,
    );
  });
}
