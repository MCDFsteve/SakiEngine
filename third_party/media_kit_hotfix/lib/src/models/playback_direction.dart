/// Playback direction for native media backends.
enum PlaybackDirection {
  forward('forward'),
  backward('backward');

  const PlaybackDirection(this.mpvValue);

  /// Value used by mpv's `play-direction` property.
  final String mpvValue;
}
