import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sakiengine/src/game/unified_game_data_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('v3 settings migrate voice volume independently into v4', () async {
    final originalPathProvider = PathProviderPlatform.instance;
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'saki-voice-volume-test-',
    );
    const projectName = 'voice-volume-migration-test';
    final saveDirectory = Directory(
      '${temporaryDirectory.path}/SakiEngine/Saves/$projectName',
    );
    await saveDirectory.create(recursive: true);
    final dataFile = File('${saveDirectory.path}/game_data.sakidata');
    await dataFile.writeAsBytes(_buildVersion3Data(soundVolume: 0.35));

    PathProviderPlatform.instance = _TestPathProvider(temporaryDirectory.path);
    addTearDown(() async {
      PathProviderPlatform.instance = originalPathProvider;
      await temporaryDirectory.delete(recursive: true);
    });

    final manager = UnifiedGameDataManager();
    await manager.init(projectName);

    expect(manager.soundVolume, 0.35);
    expect(
      manager.voiceVolume,
      0.35,
      reason: 'v3 voice playback used the persisted sound volume',
    );

    await manager.setVoiceVolume(0.72, projectName);

    expect(manager.soundVolume, 0.35);
    expect(manager.voiceVolume, 0.72);

    final persistedAudio = _readVersion4Audio(await dataFile.readAsBytes());
    expect(persistedAudio.version, 4);
    expect(persistedAudio.soundVolume, 0.35);
    expect(persistedAudio.voiceVolume, 0.72);
  });
}

final class _TestPathProvider extends PathProviderPlatform {
  _TestPathProvider(this.documentsPath);

  final String documentsPath;

  @override
  Future<String?> getApplicationSupportPath() async => documentsPath;
}

Uint8List _buildVersion3Data({required double soundVolume}) {
  final writer = _BinaryWriter();
  writer.writeInt32(3);
  writer.writeDouble(0.9);
  writer.writeBool(false);
  writer.writeBool(false);
  writer.writeDouble(50.0);
  writer.writeBool(false);
  writer.writeBool(true);
  writer.writeBool(false);
  writer.writeBool(true);
  writer.writeString('windowed');
  writer.writeString('read_only');
  writer.writeString('SourceHanSansCN');
  writer.writeString('rewind');
  writer.writeBool(true);
  writer.writeBool(true);
  writer.writeDouble(0.8);
  writer.writeDouble(soundVolume);
  writer.writeInt32(0);
  writer.writeInt32(0);
  writer.writeInt32(0);
  writer.writeInt32(0);
  return writer.takeBytes();
}

({int version, double soundVolume, double voiceVolume}) _readVersion4Audio(
  Uint8List data,
) {
  final reader = _BinaryReader(data);
  final version = reader.readInt32();
  reader.readDouble();
  reader.readBool();
  reader.readBool();
  reader.readDouble();
  reader.readBool();
  reader.readBool();
  reader.readBool();
  reader.readBool();
  reader.readString();
  reader.readString();
  reader.readString();
  reader.readString();
  reader.readBool();
  reader.readBool();
  reader.readDouble();
  final soundVolume = reader.readDouble();
  final voiceVolume = reader.readDouble();
  return (version: version, soundVolume: soundVolume, voiceVolume: voiceVolume);
}

final class _BinaryWriter {
  final BytesBuilder _bytes = BytesBuilder();

  void writeInt32(int value) {
    final data = ByteData(4)..setInt32(0, value, Endian.little);
    _bytes.add(data.buffer.asUint8List());
  }

  void writeDouble(double value) {
    final data = ByteData(8)..setFloat64(0, value, Endian.little);
    _bytes.add(data.buffer.asUint8List());
  }

  void writeBool(bool value) => _bytes.add([value ? 1 : 0]);

  void writeString(String value) {
    final encoded = utf8.encode(value);
    writeInt32(encoded.length);
    _bytes.add(encoded);
  }

  Uint8List takeBytes() => _bytes.takeBytes();
}

final class _BinaryReader {
  _BinaryReader(this.data);

  final Uint8List data;
  int offset = 0;

  int readInt32() {
    final value = ByteData.sublistView(
      data,
      offset,
      offset + 4,
    ).getInt32(0, Endian.little);
    offset += 4;
    return value;
  }

  double readDouble() {
    final value = ByteData.sublistView(
      data,
      offset,
      offset + 8,
    ).getFloat64(0, Endian.little);
    offset += 8;
    return value;
  }

  bool readBool() => data[offset++] != 0;

  String readString() {
    final length = readInt32();
    final value = utf8.decode(data.sublist(offset, offset + length));
    offset += length;
    return value;
  }
}
