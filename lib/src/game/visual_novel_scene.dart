import 'dart:math'; // Import math for max/min

import 'package:flame/game.dart';
import 'package:flutter/material.dart';
import 'package:flame/components.dart'; // Import components
import 'package:flutter/services.dart' show rootBundle; // Import rootBundle
// Import SpriteSheet
import 'package:flame/events.dart'; // Import events for TapCallbacks
import '../utils/adaptive_sizer.dart'; // Import the sizer extension
import '../widgets/constrained_scaffold.dart';
import 'package:provider/provider.dart'; // Import Provider for context.watch
import 'background_manager.dart'; // Keep import for findFirstComponentOfType
import 'character_manager.dart'; // <<< RE-ADD missing import
import 'dialogue_manager.dart'; // Import DialogueManager
import 'indicator_component.dart'; // Import IndicatorComponent
import '../widgets/menu_view.dart'; // Import MenuView
// REMOVE: import 'menu_manager.dart';

// --- Data class for Menu Items (moved here or keep separate?) ---
class MenuItem {
  final String text;
  final int targetLineIndex; // Line index to jump to after label
  MenuItem({required this.text, required this.targetLineIndex});
}

// --- Pose Definition --- 
class PoseDefinition {
  final double scale; // 0 means calculate aspect fit
  final double xcenter; // Normalized X (0.0 - 1.0)
  final double ycenter; // Normalized Y (0.0 - 1.0)
  final Anchor anchor;

  PoseDefinition({
    this.scale = 0, // Default to aspect fit
    this.xcenter = 0.5,
    this.ycenter = 0.5,
    this.anchor = Anchor.center,
  });

  @override
  String toString() {
    return 'Pose(scale: $scale, xcenter: $xcenter, ycenter: $ycenter, anchor: $anchor)';
  }
}

// +++ Character Definition +++
class CharacterDefinition {
  final String alias; // e.g., "yk"
  final String displayName; // e.g., "Yuki Cocoro"
  final String assetId; // e.g., "yukari"

  CharacterDefinition({
    required this.alias,
    required this.displayName,
    required this.assetId,
  });

  @override
  String toString() {
    return 'Character(alias: $alias, displayName: "$displayName", assetId: $assetId)';
  }
}
// +++ End Character Definition +++

// The core Flame game class for the visual novel
class VisualNovelGame extends FlameGame with TapCallbacks { // Add TapCallbacks mixin

  // <<< ADD Callback for Return >>>
  final VoidCallback? onReturnRequested;

  // Scripting & State
  List<String> _scriptLines = [];
  int _currentLine = 0;
  bool _executing = false; // Flag to prevent concurrent execution

  // Simple variable store (replace with a more robust system later)
  final Map<String, dynamic> _variables = {};

  // Track if/else state
  // Stack to handle nested ifs? For now, just the last result.
  bool? _lastIfConditionResult;

  // Regex patterns for parsing
  // MODIFIED _sayRegex to make speaker optional
  static final RegExp _sayRegex = RegExp(r'^\s*(?:([\w\d_]+)(?:\s+([\w\d_]+))?\s+)?"(.*?)"\s*$');
  // Group 1: Optional Alias, Group 2: Optional Expression, Group 3: Dialogue
  static final RegExp _menuOptionRegex = RegExp(r'^\s*"(.*?)"\s*->\s*(\w+)\s*$'); 
  static final RegExp _assignmentRegex = RegExp(r'^\s*\$(\w+)\s*=\s*(.*)$');
  static final RegExp _jumpRegex = RegExp(r'^\s*jump\s+(\w+)\s*$');

  // Component references
  // REMOVED: SpriteComponent? _backgroundComponent;
  // REMOVED: final Map<String, ({SpriteComponent component, String poseName})> _characterComponents = {};
  late final CharacterManager characterManager; // <<< ADD CharacterManager instance
  late final DialogueManager dialogueManager; // <<< ADD DialogueManager instance
  // REMOVED: late final MenuManager menuManager;

  // Pose definitions (Keep here, passed to CharacterManager)
  final Map<String, PoseDefinition> _poses = {};
  // Static default pose, also passed to CharacterManager
  static final PoseDefinition _defaultPose = PoseDefinition(
      scale: 0, xcenter: 0.5, ycenter: 1.0, anchor: Anchor.bottomCenter);

  // +++ Character Definitions +++ (Keep here, passed to CharacterManager)
  final Map<String, CharacterDefinition> _characters = {};
  // +++ End Character Definitions +++

  // Anchor parsing helper (Keep here, PoseDefinition uses it)
  static final Map<String, Anchor> _stringToAnchor = {
      'topleft': Anchor.topLeft, 'topcenter': Anchor.topCenter, 'topright': Anchor.topRight,
      'centerleft': Anchor.centerLeft, 'center': Anchor.center, 'centerright': Anchor.centerRight,
      'bottomleft': Anchor.bottomLeft, 'bottomcenter': Anchor.bottomCenter, 'bottomright': Anchor.bottomRight,
    };

  static Anchor _parseAnchor(String? name, [Anchor defaultValue = Anchor.center]) {
      if (name == null) return defaultValue;
      return _stringToAnchor[name.toLowerCase()] ?? defaultValue;
  }

  // Get a direct reference to the sizer instance
  final AdaptiveSizer _sizer = AdaptiveSizer.instance;

  // --- Managers ---
  // REMOVED: late final BackgroundManager backgroundManager;

  // Menu State (for Overlay)
  final List<MenuItem> _activeMenuItems = [];
  bool isMenuVisible = false; // Flag for Overlay builder

  // <<< ADD State to track current character poses >>>
  final Map<String, String> _characterCurrentPose = {};

  // <<< ADD Constructor to accept callback >>>
  VisualNovelGame({this.onReturnRequested});

  @override
  Future<void> onLoad() async {
    super.onLoad();
    print('VisualNovelGame onLoad called.');

    // Add background manager
    add(BackgroundManager());

    // Load configuration files FIRST
    await _loadPoses('assets/configs/poses.skp');
    await _loadCharacters('assets/configs/characters.skn');

    // <<< INITIALIZE and ADD CharacterManager AFTER loading configs >>>
    characterManager = CharacterManager(
      poses: _poses,
      characters: _characters,
      defaultPose: _defaultPose,
    );
    add(characterManager);
    // <<< END CharacterManager initialization >>>

    // <<< INITIALIZE and ADD DialogueManager >>>
    dialogueManager = DialogueManager();
    add(dialogueManager);
    // <<< END DialogueManager initialization >>>

    await _loadScript('assets/scripts/start.skr'); // Load script LAST

    if (_currentLine != -1) {
      _startExecution();
    }
  }

  Future<void> _loadScript(String path) async {
    try {
      final scriptContent = await rootBundle.loadString(path);
      _scriptLines = scriptContent.split('\n')
          .map((line) => line.trim()) // Trim whitespace
          .where((line) => line.isNotEmpty && !line.startsWith('#')) // Remove empty lines and comments
          .toList();
      _currentLine = _findLabel('start'); // Start execution at the 'start' label
      print('Script loaded successfully: ${_scriptLines.length} lines.');
      if (_currentLine == -1) {
        print("Error: 'start' label not found in script!");
        // Handle error - maybe stop execution or show an error message
      }
    } catch (e) {
      print('Error loading script $path: $e');
      // Handle error
      _currentLine = -1; // Ensure execution doesn't start on error
    }
  }

  Future<void> _loadPoses(String path) async {
    print("Loading poses from $path...");
    _poses.clear();
    try {
      final poseContent = await rootBundle.loadString(path);
      final lines = poseContent.split('\n');

      for (final line in lines) {
        final trimmedLine = line.trim();
        if (trimmedLine.isEmpty || trimmedLine.startsWith('#')) {
          continue; // Skip empty lines and comments
        }

        final parts = trimmedLine.split(':');
        if (parts.length != 2) {
          print("  Warning: Invalid pose line format (missing ':'): $trimmedLine");
          continue;
        }

        final poseName = parts[0].trim();
        final paramsString = parts[1].trim();
        final paramParts = paramsString.split(RegExp(r'\s+')); // Split by whitespace

        double scale = 0; // Default to 0 (aspect fit)
        double xcenter = 0.5;
        double ycenter = 0.5;
        Anchor anchor = Anchor.center;

        for (final param in paramParts) {
          final kv = param.split('=');
          if (kv.length != 2) continue;
          final key = kv[0].toLowerCase();
          final value = kv[1];

          switch (key) {
            case 'scale':
              final parsedScale = double.tryParse(value);
              print("    Parsing param 'scale' for $poseName: value='$value', parsed=$parsedScale");
              scale = parsedScale ?? 0;
              if (scale < 0) scale = 0; // Treat negative scale as aspect fit too
              break;
            case 'xcenter':
              xcenter = double.tryParse(value) ?? 0.5;
              break;
            case 'ycenter':
              ycenter = double.tryParse(value) ?? 0.5;
              break;
            case 'anchor':
              anchor = _parseAnchor(value, Anchor.center);
              break;
          }
        }

        _poses[poseName] = PoseDefinition(
          scale: scale,
          xcenter: xcenter,
          ycenter: ycenter,
          anchor: anchor,
        );
        print("  Loaded pose: $poseName = ${_poses[poseName]}");
      }
       print("Poses loaded successfully: ${_poses.length} definitions.");
    } catch (e) {
      print('Error loading poses $path: $e');
    }
  }

  // +++ Load Characters Method +++
  Future<void> _loadCharacters(String path) async {
    print("Loading characters from $path...");
    _characters.clear();
    try {
      final characterContent = await rootBundle.loadString(path);
      final lines = characterContent.split('\n');

      for (final line in lines) {
        final trimmedLine = line.trim();
        if (trimmedLine.isEmpty || trimmedLine.startsWith('#')) {
          continue; // Skip empty lines and comments
        }

        final parts = trimmedLine.split(':').map((p) => p.trim()).toList();
        if (parts.length != 3) {
          print("  Warning: Invalid character line format (expected 3 parts separated by ':'): $trimmedLine");
          continue;
        }

        final alias = parts[0];
        String displayName = parts[1];
        final assetId = parts[2];

        if (alias.isEmpty || displayName.isEmpty || assetId.isEmpty) {
           print("  Warning: Invalid character line (alias, name, or assetId is empty): $trimmedLine");
           continue;
        }

        // Remove quotes from display name if present
        if (displayName.startsWith('"') && displayName.endsWith('"')) {
          displayName = displayName.substring(1, displayName.length - 1);
        }

        if (_characters.containsKey(alias)) {
          print("  Warning: Duplicate character alias found: '$alias'. Overwriting previous definition.");
        }

        final definition = CharacterDefinition(
          alias: alias,
          displayName: displayName,
          assetId: assetId,
        );
        _characters[alias] = definition;
        print("  Loaded character: ${definition.toString()}");
      }
      print("Characters loaded successfully: ${_characters.length} definitions.");
    } catch (e) {
      print('Error loading characters $path: $e');
    }
  }
  // +++ End Load Characters Method +++

  int _findLabel(String labelName) {
    final labelMarker = 'label $labelName:';
    // Find the line *after* the label definition
    for (int i = 0; i < _scriptLines.length; i++) {
        if (_scriptLines[i] == labelMarker) {
            return i + 1; // Start executing the line AFTER the label
        }
    }
    print("ERROR: Label '$labelName' not found!"); // Add error log
    return -1; // Label not found
  }

  void _startExecution() {
      if (!_executing) {
          _executing = true;
          _variables.clear(); // Clear variables at start
          _lastIfConditionResult = null;
          dialogueManager.dismissDialogue(); // Ensure no leftover dialogue from previous runs
          _hideMenuOverlay(); // Ensure menu overlay is hidden initially
          _executeNextCommandLoop(); // Start the loop
      }
  }

  // --- Execution Loop - Simplified continuation logic ---
  void _executeNextCommandLoop() async {
      while (_executing && _currentLine >= 0 && _currentLine < _scriptLines.length) {
          final line = _scriptLines[_currentLine];
          print('Executing line $_currentLine: $line');

          int lineBeforeExecute = _currentLine;

          await _parseAndExecuteCommand(line); 

          // If execution stopped, break the loop
          if (!_executing) {
             break;
          }

          // Increment line counter ONLY if the command handler 
          // did NOT change the current line (e.g., via jump or menu choice)
          if (_currentLine == lineBeforeExecute) {
              _currentLine++;
          }
          
          await Future.delayed(Duration(milliseconds: 5)); 
      }

      // Handle end of script execution or halt
      if (_executing) { 
        print('--- End of script execution ---');
        _executing = false;
      } else {
         print('--- Script execution halted (e.g., by return, error, or pause state didn\'t resume) ---');
      }
  }

  // Returns void now, pauses are handled in loop
  Future<void> _parseAndExecuteCommand(String line) async {
    if (line.startsWith('label ')) {
        print("  -> Encountered label line: $line (Skipping)");
    }
    else if (line.startsWith('scene ')) {
      await _handleScene(line);
    }
    else if (line.startsWith('show ')) {
      await _handleShow(line);
    }
    else if (_sayRegex.hasMatch(line)) {
       // _handleSay now fully manages its pause and resume
       await _handleSay(line);
    }
    else if (line.trim() == 'menu:') {
        _handleMenuStart(line);
    }
    else if (_menuOptionRegex.hasMatch(line)) {
        _handleMenuOption(line);
    }
    else if (line.trim() == 'endmenu') {
        _handleMenuEnd(line);
    }
    else if (_assignmentRegex.hasMatch(line)) {
        _handleAssignment(line);
    }
    else if (line.startsWith('jump ')) {
        _handleJump(line); // Jump modifies _currentLine directly
    }
    else if (line.startsWith('if ')) {
       _handleIf(line); // If might modify _currentLine via skips
    }
    else if (line == 'else:') {
        _handleElse(line); // Else might modify _currentLine via skips
    }
    else if (line == 'endif') {
        _handleEndif(line);
    }
    else if (line == 'return') {
        _handleReturn(line); // Return sets _executing to false
    }
    else {
      print('  -> Unknown command: $line');
    }
  }

  Future<void> _handleScene(String line) async {
    final sceneIdentifier = line.substring('scene '.length).trim();
    if (sceneIdentifier.isEmpty) {
      print("Error: Missing scene identifier in '$line'");
      return;
    }

    // <<< HIDE existing characters on scene change >>>
    characterManager.hideAllCharacters();

    // Delegate background change to the manager component
    try {
      final bgManager = children.whereType<BackgroundManager>().firstOrNull;
      if (bgManager != null) {
        await bgManager.changeBackground(sceneIdentifier);
      } else {
        print("Error: BackgroundManager component not found in game children.");
      }
    } catch (e) {
      print("Error accessing BackgroundManager: $e");
    }
  }

  // --- MODIFIED _handleShow to track pose ---
  Future<void> _handleShow(String line) async {
    final parts = line.substring('show '.length).trim().split(' ');
    if (parts.isNotEmpty && parts[0].isNotEmpty) {
        final characterAlias = parts[0];
        String expression = 'default';
        String poseName = 'center_default'; 
        int currentPartIndex = 1;
        if (currentPartIndex < parts.length && parts[currentPartIndex] != 'at') {
            expression = parts[currentPartIndex];
            currentPartIndex++;
        }
        if (currentPartIndex < parts.length - 1 && parts[currentPartIndex] == 'at') {
            poseName = parts[currentPartIndex + 1];
        }
        print('  -> Show command: Alias "$characterAlias" (Expression: "$expression") at pose "$poseName"');
        await characterManager.showCharacter(
          characterAlias: characterAlias,
          expression: expression,
          poseName: poseName,
        );
        // <<< Record the pose used for this character >>>
        _characterCurrentPose[characterAlias] = poseName;

    } else {
        print('  -> Error parsing show command: Invalid format in "$line"');
    }
}

  // --- MODIFIED _handleSay - Default speaker is literal "空白" --- 
  Future<void> _handleSay(String line) async { 
      final match = _sayRegex.firstMatch(line);
      if (match != null && match.groupCount >= 3) { 
          String? characterAlias = match.group(1); // Explicitly check if alias was provided
          final expression = match.group(2); 
          final dialogue = match.group(3)?.trim() ?? ''; 

          // Determine Display Name
          String displayName;
          if (characterAlias == null) {
              // <<< If no alias in script, use literal "空白" >>>
              displayName = "空白";
          } else {
              // <<< Alias provided, look it up >>>
              final characterDef = _characters[characterAlias];
              if (characterDef != null) {
                  displayName = characterDef.displayName;
              } else {
                  // Use alias as display name if provided but not defined
                  displayName = characterAlias; 
                  print('  Warning: Character alias "$characterAlias" not found in definitions. Using alias as display name.');
              }
          }

          final exprLog = expression != null ? " ($expression)" : "";
          print('  -> Say command: $displayName$exprLog says "$dialogue" (Alias: ${characterAlias ?? 'none'})');
          
          // Update character sprite if expression provided AND it's not the empty speaker
          if (expression != null && expression.isNotEmpty && characterAlias != null) { // Check alias is not null
             final currentPose = _characterCurrentPose[characterAlias] ?? 'center_default';
             print('    Updating character $characterAlias to expression "$expression" at pose "$currentPose"');
             await characterManager.showCharacter(
                 characterAlias: characterAlias, 
                 expression: expression, 
                 poseName: currentPose
             );
          }
          
          await dialogueManager.showDialogue(displayName, dialogue);
          print("--- Dialogue dismissed, resuming execution ---");
          _executing = true; 

      } else {
           print('  -> Error parsing say command (Regex failed or wrong group count): $line');
           _executing = false; 
      }
  }

  // --- REWRITTEN Menu Handlers ---
  void _handleMenuStart(String line) {
      print('  -> Menu Start: Clearing active menu items.');
      _activeMenuItems.clear();
      isMenuVisible = false; // Ensure flag is reset
  }

  void _handleMenuOption(String line) {
      final match = _menuOptionRegex.firstMatch(line);
      // New Regex: group(1) is text, group(2) is label name
      if (match != null && match.groupCount >= 2) {
          final optionText = match.group(1)?.trim() ?? '';
          final targetLabel = match.group(2)?.trim() ?? '';
          print('    -> Menu Option: "$optionText" -> $targetLabel');

          if (optionText.isEmpty || targetLabel.isEmpty) {
              print('      ERROR: Invalid menu option format (empty text or label).');
              return;
          }

          final targetLine = _findLabel(targetLabel); // Get line index *after* label
          if (targetLine != -1) {
              _activeMenuItems.add(MenuItem(text: optionText, targetLineIndex: targetLine));
              print('      Added menu item: "$optionText" -> line $targetLine');
    } else {
              print('      ERROR: Target label "$targetLabel" not found for menu option.');
              // Optionally add item with invalid target (-1) or skip?
          }
          // NOTE: No need to change _currentLine here. Let loop increment.
      } else {
           print('  -> Error parsing menu option (Regex failed or wrong format): $line');
      }
  }

  // --- MODIFIED _handleMenuEnd - Remove recursive call ---
  void _handleMenuEnd(String line) async {
      print('  -> Menu End: Preparing to show menu overlay.');
      if (_activeMenuItems.isEmpty) {
          print('    WARN: endmenu encountered with no active menu items. Skipping.');
          return; // Loop will auto-increment past endmenu
      }

      isMenuVisible = true;
      overlays.add('MenuOverlay');
      _executing = false; // PAUSE script execution
      print('    MenuOverlay added. Script execution paused.');
      
      // Wait for the overlay to call selectMenuOption which will resume execution
  }

  // --- MODIFIED selectMenuOption - Handles resume ---
  void selectMenuOption(int targetLineIndex) {
      print("VisualNovelGame: Menu option selected! Target line: $targetLineIndex");
      if (!isMenuVisible) {
           print("WARN: selectMenuOption called when menu wasn't visible?");
           return;
      }
      
      _hideMenuOverlay(); // Hide the menu

      if (targetLineIndex >= 0) {
         _currentLine = targetLineIndex; // Set jump target
         _executing = true; // RESUME script execution
         _executeNextCommandLoop(); // Explicitly start loop from the target line
      } else {
          print("ERROR: Invalid target line index from menu selection. Halting.");
          _executing = false; 
      }
  }

  // Helper to ensure menu overlay is hidden
  void _hideMenuOverlay() {
     if (isMenuVisible) {
        overlays.remove('MenuOverlay');
        isMenuVisible = false;
        _activeMenuItems.clear(); // Clear items when menu is hidden
        print("MenuOverlay removed.");
     }
  }

  void _handleAssignment(String line) {
       final match = _assignmentRegex.firstMatch(line);
      if (match != null && match.groupCount >= 2) {
          final variableName = match.group(1) ?? '';
          final valueString = (match.group(2) ?? '').trim();
          dynamic value;
          // Basic type inference (improve later)
          if (valueString.startsWith('"') && valueString.endsWith('"')) {
              value = valueString.substring(1, valueString.length - 1);
          } else if (int.tryParse(valueString) != null) {
              value = int.parse(valueString);
          } else if (double.tryParse(valueString) != null) {
              value = double.parse(valueString);
          } else if (valueString == 'true') {
              value = true;
          } else if (valueString == 'false') {
              value = false;
          }
           else {
              // Check if it's a variable name
              if (_variables.containsKey(valueString)) {
                 value = _variables[valueString]; // Assign value of another variable
                 print('      (Assigned from variable $valueString)');
              } else {
                value = valueString; // Treat as string if unknown identifier or bareword
                print('      (Treated as string)');
              }
          }
          print('  -> Assignment: Set $variableName = $value (${value.runtimeType})');
          _variables[variableName] = value;
          // TODO: Potentially update UI if variable is displayed
      } else {
           print('  -> Error parsing assignment (Regex failed): $line');
      }
  }

  void _handleJump(String line) {
      final targetLabel = line.substring('jump '.length).trim();
      if (targetLabel.isNotEmpty) {
          print('  -> Jump command: Jumping to label "$targetLabel"');
          final targetLine = _findLabel(targetLabel);
          if (targetLine != -1) {
              _currentLine = targetLine; // Set the next line to execute
              // The loop will continue from the new _currentLine
          } else {
              print('  -> Error: Label "$targetLabel" not found for jump in "$line"');
              _executing = false; // Stop execution if label not found
          }
      } else {
          print('  -> Error parsing jump command: Missing label name in "$line"');
          _executing = false; // Stop execution
      }
  }

  void _handleIf(String line) {
      final condition = line.substring('if '.length).trim().replaceAll(':', '');
      print('  -> If command: Condition "$condition"');
      bool conditionResult = _evaluateCondition(condition);
      _lastIfConditionResult = conditionResult; // Store result
      print("    Condition result: $conditionResult");
      if (!conditionResult) {
          // If condition is false, skip to the corresponding else or endif
           _skipToElseOrEndif();
      }
      // If true, execution continues normally to the next line (loop handles increment)
  }

   // Basic condition evaluator (needs significant expansion for complex expressions)
  bool _evaluateCondition(String condition) {
      // Example: mood == "happy"
      final parts = condition.split(' ');
      if (parts.length == 3) {
          final varName = parts[0];
          final op = parts[1];
          String valueString = parts[2];
          dynamic expectedValue;

          if (valueString.startsWith('"') && valueString.endsWith('"')) {
              expectedValue = valueString.substring(1, valueString.length - 1);
          } else if (int.tryParse(valueString) != null) {
              expectedValue = int.parse(valueString);
          } // Add other types (bool, double) if needed

          final actualValue = _variables[varName];

          if (op == '==') {
              return actualValue == expectedValue;
          } else if (op == '!=') {
               return actualValue != expectedValue;
           } // Add other operators (>, <, >=, <=) if needed
      }
      print("    Warning: Cannot evaluate complex condition '$condition'");
      return false; // Default to false for unparseable conditions
  }

   void _skipToElseOrEndif() {
      print("    Skipping block due to false condition...");
      int ifLevel = 1; // Start inside the current 'if'
      int lineToTest = _currentLine; // Start checking from the line *after* the 'if'

      while (lineToTest < _scriptLines.length) {
          final testLine = _scriptLines[lineToTest];
          if (testLine.startsWith('if ')) {
              ifLevel++;
          } else if (testLine == 'endif') {
              ifLevel--;
              if (ifLevel == 0) {
                  // Found the matching endif for the original 'if'
                  _currentLine = lineToTest; // Go to the endif line itself
                   print("      Found matching endif at line $lineToTest. Resuming at next line.");
                  return;
              }
          } else if (testLine == 'else:' && ifLevel == 1) {
               // Found the 'else' for the original 'if'
               _currentLine = lineToTest; // Go to the else line itself
               print("      Found matching else at line $lineToTest. Resuming at next line.");
               return;
          }
          lineToTest++;
      }
      // If loop finishes, endif/else not found
      print("    Error: Could not find matching 'else:' or 'endif' for 'if' at line $_currentLine");
      _executing = false; // Stop execution
  }


  void _handleElse(String line) {
      print('  -> Else command');
      if (_lastIfConditionResult == true) {
          // If the preceding 'if' was TRUE, skip this else block
          print("    Skipping else block because if was true...");
          _skipToEndif();
      } else {
          // If the preceding 'if' was FALSE (or null?), execute this block normally.
          print("    Executing else block...");
          // Execution continues to the next line (loop handles increment)
           _lastIfConditionResult = null; // Clear state after handling else
      }
  }

   void _skipToEndif() {
       print("    Skipping to endif...");
      int ifLevel = 1; // Consider the 'if' whose block we are skipping the 'else' of
      int lineToTest = _currentLine; // Start checking from the line *after* the 'else'

      while (lineToTest < _scriptLines.length) {
           final testLine = _scriptLines[lineToTest];
          if (testLine.startsWith('if ')) {
              ifLevel++;
          } else if (testLine == 'endif') {
              ifLevel--;
              if (ifLevel == 0) {
                   // Found the matching endif
                  _currentLine = lineToTest; // Go to the endif line itself
                  print("      Found matching endif at line $lineToTest. Resuming at next line.");
                  return;
              }
          }
           lineToTest++;
      }
      // If loop finishes, endif not found
      print("    Error: Could not find matching 'endif' for 'else' at line $_currentLine");
      _executing = false; // Stop execution
  }


   void _handleEndif(String line) {
      print('  -> Endif command');
      // Marks the end of an if/else block. Clear the state.
      _lastIfConditionResult = null;
      // Execution continues normally
  }

  // --- MODIFIED _handleReturn to use callback ---
  void _handleReturn(String line) {
      print('  -> Return command. Requesting navigation back...');
      _executing = false; // Stop script execution first
      onReturnRequested?.call(); // Call the callback if provided
      // If callback is null, it just stops execution as before.
  }

  // --- MODIFIED onTapUp - Global Tap Handling ---
  @override
  void onTapUp(TapUpEvent event) {
    super.onTapUp(event);
    print("VisualNovelGame: Global onTapUp detected.");

    // Important: Check dialogue visibility FIRST. 
    // If dialogue is visible, tap should *only* advance dialogue.
    if (dialogueManager.isDialogueVisible) {
      print("  -> Dialogue is visible. Dismissing dialogue.");
      dialogueManager.dismissDialogue();
      // Note: dismissDialogue() completes the future, which resumes execution
      // in the _handleSay method if it was awaiting.
      return; // Don't process further if dialogue was dismissed.
    }

    // If dialogue is NOT visible, check for other potential tap targets.
    // Currently, none defined, but could be added later (e.g., interactable elements)
    print("  -> Dialogue not visible. No action defined for this tap.");

    // REMOVED the old incorrect logic:
    /*
    print("VisualNovelGame onTapUp - No action defined for this tap.");
    */
  }

  // --- MODIFIED onGameResize (No changes needed, CharacterManager handles itself) ---
  @override
  void onGameResize(Vector2 size) {
    super.onGameResize(size);
    print("VisualNovelGame onGameResize called with: $size");
    // Managers handle their own resize via Component lifecycle
  }

}

// --- VisualNovelScreen (Use MenuView for Overlay) ---
class VisualNovelScreen extends StatelessWidget {
  const VisualNovelScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Constrained16x9Scaffold(
      body: GameWidget<VisualNovelGame>(
        game: VisualNovelGame(
          onReturnRequested: () {
             print("VisualNovelScreen: Return requested, popping route.");
             if (context.mounted) { 
                Navigator.pop(context);
             }
          },
        ), 
        overlayBuilderMap: {
          'MenuOverlay': (context, game) {
            // <<< Use the new MenuView widget >>>
             if (!game.isMenuVisible || game._activeMenuItems.isEmpty) {
               // Avoid building if not visible or no items
               return const SizedBox.shrink(); 
             }
             print("Building MenuOverlay with MenuView. Items count: ${game._activeMenuItems.length}");
            return MenuView(
              menuItems: game._activeMenuItems,
              onOptionSelected: game.selectMenuOption,
            );
            // <<< End MenuView usage >>>
            
            // REMOVED Temporary builder:
            /*
            print("Building MenuOverlay. Items count: ${game._activeMenuItems.length}"); 
            return Center(
               child: Container(
                 padding: const EdgeInsets.all(20),
                 color: Colors.black.withOpacity(0.7),
                 child: Column(
                   mainAxisSize: MainAxisSize.min,
                   children: game._activeMenuItems.map((item) {
                     print("  Mapping menu item: ${item.text} -> ${item.targetLineIndex}");
                     return ElevatedButton(
                       onPressed: () {
                         print("  Button pressed for item: ${item.text}");
                         game.selectMenuOption(item.targetLineIndex);
                       },
                       child: Text(item.text),
                     );
                   }).toList(),
                 ),
               ),
            );
            */
          },
        },
      ),
    );
  }
}

// --- REMOVED Dialogue Box Widget --- 
/*
class DialogueBox extends StatelessWidget {
  final String character;
  final String dialogue;

  const DialogueBox({
    super.key,
    required this.character,
    required this.dialogue,
  });

  @override
  Widget build(BuildContext context) {
    // WATCH the sizer instance for changes
    context.watch<AdaptiveSizer>(); 
    
    // Calculate dimensions using extensions
    final boxHeight = 0.25.sh;
    final boxWidth = 0.9.sw;
    final bottomMargin = 0.05.sh;
    final horizontalMargin = (1.sw - boxWidth) / 2;
    final padding = 0.02.sw;
    final spacing = 0.01.sh;
    final iconSize = 0.03.sh;
    final titleFontSize = 18.sp;
    final dialogueFontSize = 16.sp;

    return Positioned(
      bottom: bottomMargin,
      left: horizontalMargin,
      right: horizontalMargin,
      child: Material(
        color: Colors.black.withOpacity(0.7),
        borderRadius: BorderRadius.circular(10),
        elevation: 4,
        child: Container(
          padding: EdgeInsets.all(padding),
          width: boxWidth,
          height: boxHeight,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (character.isNotEmpty && character != 'Narrator')
                Text(
                  character,
                  style: TextStyle(
                    color: Colors.yellowAccent,
                    fontWeight: FontWeight.bold,
                    fontSize: titleFontSize, // Apply scaled size
                  ),
                ),
              if (character.isNotEmpty && character != 'Narrator')
                 SizedBox(height: spacing),
              Expanded(
                child: SingleChildScrollView(
                   child: Text(
                      dialogue,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: dialogueFontSize, // Apply scaled size
                     ),
                   ),
                ),
              ),
              Align(
                  alignment: Alignment.bottomRight,
                  child: Icon(
                      Icons.arrow_drop_down,
                      color: Colors.white.withOpacity(0.5),
                      size: iconSize // Apply scaled size
                   )
              )
            ],
          ),
        ),
      ),
    );
  }
}
*/