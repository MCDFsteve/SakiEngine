/// Returns whether [path] points to a file-system location rather than a
/// Flutter asset key.
///
/// Windows `canonicalize` may return extended paths such as
/// `\\?\C:\game\Assets\image.png`. Those paths start with a backslash, so a
/// drive-letter-only check incorrectly treats them as bundled assets.
bool isFileSystemAssetPath(String path) {
  final value = path.trim();
  if (value.isEmpty) {
    return false;
  }

  return value.startsWith('/') ||
      value.codeUnitAt(0) == 0x5c ||
      RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value);
}
