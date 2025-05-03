import 'package:flutter/foundation.dart';

/// Holds the current state of the dialogue to be displayed.
class DialogueState {
  final String character;
  final String dialogue;
  final bool isVisible;

  // Default state (hidden)
  const DialogueState({
    this.character = '',
    this.dialogue = '',
    this.isVisible = false,
  });

  // Creates a copy with updated values.
  DialogueState copyWith({
    String? character,
    String? dialogue,
    bool? isVisible,
  }) {
    return DialogueState(
      character: character ?? this.character,
      dialogue: dialogue ?? this.dialogue,
      isVisible: isVisible ?? this.isVisible,
    );
  }
}

/// Manages the DialogueState and notifies listeners of changes.
class DialogueStateNotifier extends ChangeNotifier {
  DialogueState _state = const DialogueState(); // Initial hidden state

  DialogueState get state => _state;

  /// Shows a new dialogue line.
  void showDialogue(String character, String dialogue) {
    _state = _state.copyWith(
      character: character,
      dialogue: dialogue,
      isVisible: true,
    );
    notifyListeners();
    print("DialogueStateNotifier: showDialogue - Char: '$character', Visible: true");
  }

  /// Hides the dialogue display.
  void hideDialogue() {
    if (_state.isVisible) {
      _state = _state.copyWith(isVisible: false);
      notifyListeners();
      print("DialogueStateNotifier: hideDialogue - Visible: false");
    }
  }

  /// Clears dialogue content and hides it.
  void clearAndHideDialogue() {
     _state = const DialogueState(); // Reset to default hidden state
     notifyListeners();
     print("DialogueStateNotifier: clearAndHideDialogue");
  }
} 