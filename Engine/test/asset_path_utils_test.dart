import 'package:flutter_test/flutter_test.dart';
import 'package:sakiengine/src/utils/asset_path_utils.dart';

void main() {
  group('isFileSystemAssetPath', () {
    test('recognizes Windows extended and UNC paths', () {
      expect(
        isFileSystemAssetPath(
          r'\\?\C:\Users\tester\Game\Assets\gui\dialogue_panel.png',
        ),
        isTrue,
      );
      expect(
        isFileSystemAssetPath(r'\\server\share\Assets\background.png'),
        isTrue,
      );
    });

    test('recognizes regular absolute paths', () {
      expect(isFileSystemAssetPath(r'C:\Game\Assets\image.png'), isTrue);
      expect(isFileSystemAssetPath('/opt/game/Assets/image.png'), isTrue);
    });

    test('keeps Flutter asset keys as bundle paths', () {
      expect(isFileSystemAssetPath('Assets/gui/dialogue_panel.png'), isFalse);
      expect(isFileSystemAssetPath('backgrounds/room_night'), isFalse);
    });
  });
}
