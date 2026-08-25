import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sakiengine/src/widgets/game_style_slider.dart';
import 'package:sakiengine/src/widgets/settings/audio_settings_tab.dart';
import 'package:sakiengine/src/utils/music_manager.dart';

void main() {
  testWidgets('audio settings expose an independent voice volume slider', (
    tester,
  ) async {
    double? changedVoiceVolume;
    double? changedSoundVolume;

    Widget buildSubject({required double width, required double height}) {
      return MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: width,
              height: height,
              child: AudioSettingsTab(
                musicEnabled: true,
                musicVolume: 0.2,
                soundVolume: 0.4,
                voiceVolume: 0.6,
                onMusicEnabledChanged: (_) {},
                onMusicVolumeChanged: (_) {},
                onSoundVolumeChanged: (value) => changedSoundVolume = value,
                onVoiceVolumeChanged: (value) => changedVoiceVolume = value,
              ),
            ),
          ),
        ),
      );
    }

    await tester.pumpWidget(buildSubject(width: 760, height: 500));

    final voiceSlider = tester.widget<GameStyleSlider>(
      find.byKey(const ValueKey('voice-volume-slider')),
    );
    expect(voiceSlider.value, 0.6);

    voiceSlider.onChanged(0.3);
    expect(changedVoiceVolume, 0.3);
    expect(changedSoundVolume, isNull);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(buildSubject(width: 400, height: 560));
    await tester.pump();

    expect(find.byKey(const ValueKey('voice-volume-slider')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'character voice controls show avatars and preview on change end',
    (tester) async {
      const profiles = [
        VoiceCharacterProfile(
          id: 'xiayo',
          displayName: '夏悠',
          avatarAsset: 'missing/xiayo.webp',
          previewVoiceAsset: 'Assets/voice/cp0/xiayo_001.m4a',
          voiceFilePrefixes: ['xiayo_'],
        ),
        VoiceCharacterProfile(
          id: 'gonna',
          displayName: '李宫娜',
          avatarAsset: 'missing/gonna.webp',
          previewVoiceAsset: 'Assets/voice/cp0/gonna_001.m4a',
          voiceFilePrefixes: ['gonna_'],
        ),
      ];
      String? changedCharacterId;
      double? changedCharacterVolume;
      String? previewedCharacterId;
      double? previewedCharacterVolume;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              height: 560,
              child: AudioSettingsTab(
                musicEnabled: true,
                musicVolume: 0.2,
                soundVolume: 0.4,
                voiceVolume: 0.6,
                onMusicEnabledChanged: (_) {},
                onMusicVolumeChanged: (_) {},
                onSoundVolumeChanged: (_) {},
                onVoiceVolumeChanged: (_) {},
                voiceCharacterProfiles: profiles,
                voiceCharacterVolumes: const {'xiayo': 0.7, 'gonna': 0.3},
                onVoiceCharacterVolumeChanged: (id, value) {
                  changedCharacterId = id;
                  changedCharacterVolume = value;
                },
                onVoiceCharacterVolumeChangeEnd: (id, value) {
                  previewedCharacterId = id;
                  previewedCharacterVolume = value;
                },
              ),
            ),
          ),
        ),
      );

      expect(
        find.byKey(const ValueKey('voice-character-avatar-xiayo')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('voice-character-avatar-gonna')),
        findsOneWidget,
      );

      final slider = tester.widget<GameStyleSlider>(
        find.byKey(const ValueKey('voice-character-slider-xiayo')),
      );
      expect(
        tester
            .getCenter(
              find.byKey(const ValueKey('voice-character-avatar-xiayo')),
            )
            .dx,
        lessThan(
          tester
              .getCenter(
                find.byKey(const ValueKey('voice-character-slider-xiayo')),
              )
              .dx,
        ),
      );
      expect(slider.value, 0.7);
      slider.onChanged(0.4);
      slider.onChangeEnd?.call(0.4);

      expect(changedCharacterId, 'xiayo');
      expect(changedCharacterVolume, 0.4);
      expect(previewedCharacterId, 'xiayo');
      expect(previewedCharacterVolume, 0.4);
    },
  );
}
