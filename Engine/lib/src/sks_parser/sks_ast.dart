abstract class SksNode {}

class ScriptNode implements SksNode {
  final List<SksNode> children;
  ScriptNode(this.children);
}

class AnimeNode implements SksNode {
  final String animeName;
  final bool loop; // 是否循环播放
  final bool keep; // 新增：是否在播放完成后保留（阻止自动消失）
  final String? transitionType; // 可选的转场效果
  final double? timer; // 可选的计时器

  AnimeNode(
    this.animeName, {
    this.loop = false, // 默认不循环
    this.keep = false, // 默认不保留，播放完就消失
    this.transitionType,
    this.timer,
  });

  @override
  String toString() {
    return 'AnimeNode(animeName: $animeName, loop: $loop, keep: $keep, transitionType: $transitionType, timer: $timer)';
  }
}

/// Clears the currently active full-screen anime overlay.
class StopAnimeNode implements SksNode {}

class ShowNode implements SksNode {
  final String character;
  final String? pose;
  final String? expression;
  final String? position;
  final String? animation;
  final int? repeatCount;
  ShowNode(this.character,
      {this.pose,
      this.expression,
      this.position,
      this.animation,
      this.repeatCount});
}

class CgNode implements SksNode {
  final String character;
  final String? pose;
  final String? expression;
  final String? position;
  final String? transitionType;
  final String? animation;
  final int? repeatCount;
  CgNode(this.character,
      {this.pose,
      this.expression,
      this.position,
      this.transitionType,
      this.animation,
      this.repeatCount});
}

class HideNode implements SksNode {
  final String character;
  final bool immediate;
  HideNode(this.character, {this.immediate = false});
}

class MovieNode implements SksNode {
  final String movieFile;
  final double? timer;
  final List<String>? layers;
  final String? transitionType;
  final String? animation;
  final int? repeatCount;
  MovieNode(this.movieFile,
      {this.timer,
      this.layers,
      this.transitionType,
      this.animation,
      this.repeatCount});
}

class BackgroundNode implements SksNode {
  final String background;
  final double? timer;
  final List<String>? layers; // 新增：多图层支持
  final String? transitionType; // 新增：转场类型支持 (with语法)
  final String? animation; // 新增：动画类型支持 (an语法)
  final int? repeatCount; // 新增：重复次数支持 (repeat语法)
  BackgroundNode(this.background,
      {this.timer,
      this.layers,
      this.transitionType,
      this.animation,
      this.repeatCount});
}

class SayNode implements SksNode {
  final String? character;
  final String dialogue;
  final String? inlineApiToken; // 引号前角色参数中的 api token（项目层可自定义语义）
  final String? dialogueTag; // 对话行尾的扩展 token（项目层可自定义语义）
  final String? tailCharacter; // 旁白行引号后角色控制：例如 "..." aru normal
  final String? tailPose; // 旁白行尾部控制pose（可选）
  final String? tailExpression; // 旁白行尾部控制expression（可选）
  final String? tailAnimation; // 旁白行尾部控制动画（an语法）
  final int? tailRepeatCount; // 旁白行尾部动画重复次数（repeat语法）
  final String? sourceFile; // 源脚本文件（不含扩展名）
  final int? sourceLine; // 源脚本行号（1-based）
  final String? pose;
  final String? expression;
  final String? position;
  final String? animation;
  final int? repeatCount;
  final String? startExpression; // 时序切换的起始差分
  final double? switchDelay; // 切换延迟时间（秒）
  final String? endExpression; // 时序切换的目标差分

  SayNode({
    this.character,
    required this.dialogue,
    this.inlineApiToken,
    this.dialogueTag,
    this.tailCharacter,
    this.tailPose,
    this.tailExpression,
    this.tailAnimation,
    this.tailRepeatCount,
    this.sourceFile,
    this.sourceLine,
    this.pose,
    this.expression,
    this.position,
    this.animation,
    this.repeatCount,
    this.startExpression,
    this.switchDelay,
    this.endExpression,
  });

  /// 检查是否为时序差分切换节点
  bool get hasTimedExpression =>
      startExpression != null && endExpression != null && switchDelay != null;
}

class ChoiceOptionNode {
  final String text;
  final String targetLabel;
  ChoiceOptionNode(this.text, this.targetLabel);
}

class MenuNode implements SksNode {
  final List<ChoiceOptionNode> choices;
  MenuNode(this.choices);
}

class LabelNode implements SksNode {
  final String name;
  LabelNode(this.name);
}

class ReturnNode implements SksNode {}

class JumpNode implements SksNode {
  final String targetLabel;
  final String? conditionVariable;
  final bool? conditionValue;

  JumpNode(
    this.targetLabel, {
    this.conditionVariable,
    this.conditionValue,
  }) : assert(
          (conditionVariable == null) == (conditionValue == null),
          '条件变量与条件值必须同时提供',
        );

  bool get isConditional => conditionVariable != null;
}

class CommentNode implements SksNode {
  final String comment;
  CommentNode(this.comment);

  @override
  String toString() => '// $comment';
}

class NvlNode implements SksNode {}

class EndNvlNode implements SksNode {}

class NvlnNode implements SksNode {} // 新增：nvln（无遮罩NVL模式）

class EndNvlnNode implements SksNode {} // 新增：endnvln

class NvlMovieNode implements SksNode {}

class EndNvlMovieNode implements SksNode {}

class FxNode implements SksNode {
  final String filterString;
  final String? sourceFile; // 源脚本文件（不含扩展名）
  final int? sourceLine; // 源脚本行号（1-based）
  FxNode(this.filterString, {this.sourceFile, this.sourceLine});
}

class PlayMusicNode implements SksNode {
  final String musicFile;
  PlayMusicNode(this.musicFile);
}

class StopMusicNode implements SksNode {
  StopMusicNode();
}

class PlaySoundNode implements SksNode {
  final String soundFile;
  final bool loop;
  PlaySoundNode(this.soundFile, {this.loop = false});
}

class StopSoundNode implements SksNode {
  StopSoundNode();
}

/// Plays one non-looping dialogue voice cue on the dedicated voice channel.
class VoiceNode implements SksNode {
  final String voiceFile;
  VoiceNode(this.voiceFile);
}

/// Stops the currently playing dialogue voice cue.
class StopVoiceNode implements SksNode {
  StopVoiceNode();
}

class ApiCallNode implements SksNode {
  final String apiName;
  final Map<String, String> parameters;

  ApiCallNode(this.apiName, {Map<String, String>? parameters})
      : parameters = Map.unmodifiable(parameters ?? const <String, String>{});
}

class BoolNode implements SksNode {
  final String variableName;
  final bool value;
  BoolNode(this.variableName, this.value);
}

class ConditionalSayNode implements SksNode {
  final String dialogue;
  final String? character;
  final String? inlineApiToken; // 引号前角色参数中的 api token（项目层可自定义语义）
  final String? dialogueTag; // 对话行尾的扩展 token（项目层可自定义语义）
  final String? tailCharacter; // 旁白行引号后角色控制：例如 "..." aru normal
  final String? tailPose; // 旁白行尾部控制pose（可选）
  final String? tailExpression; // 旁白行尾部控制expression（可选）
  final String? tailAnimation; // 旁白行尾部控制动画（an语法）
  final int? tailRepeatCount; // 旁白行尾部动画重复次数（repeat语法）
  final String? sourceFile; // 源脚本文件（不含扩展名）
  final int? sourceLine; // 源脚本行号（1-based）
  final String conditionVariable;
  final bool conditionValue;
  final String? pose;
  final String? expression;
  final String? position;
  final String? animation;
  final int? repeatCount;

  ConditionalSayNode({
    required this.dialogue,
    this.character,
    this.inlineApiToken,
    this.dialogueTag,
    this.tailCharacter,
    this.tailPose,
    this.tailExpression,
    this.tailAnimation,
    this.tailRepeatCount,
    this.sourceFile,
    this.sourceLine,
    required this.conditionVariable,
    required this.conditionValue,
    this.pose,
    this.expression,
    this.position,
    this.animation,
    this.repeatCount,
  });
}

class ShakeNode implements SksNode {
  final double? duration;
  final double? intensity;
  final String? target;

  ShakeNode({
    this.duration,
    this.intensity,
    this.target,
  });

  @override
  String toString() {
    return 'ShakeNode(duration: $duration, intensity: $intensity, target: $target)';
  }
}

class PauseNode implements SksNode {
  final double duration; // 暂停时长（秒）

  PauseNode(this.duration);

  @override
  String toString() {
    return 'PauseNode(duration: $duration)';
  }
}
