import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

Map<String, String> globalHostTokens = {};

Future<String> getSettingsPath() async {
  if (Platform.isWindows) {
    final dir = await getApplicationSupportDirectory();
    final newPath = '${dir.path}${Platform.pathSeparator}ravestreamer_settings.json';
    final legacyFile = File('C:\\RaveStreamer\\settings.json');
    final newFile = File(newPath);
    if (!await newFile.exists() && await legacyFile.exists()) {
      try {
        await newFile.parent.create(recursive: true);
        await legacyFile.copy(newPath);
      } catch (_) {}
    }
    return newPath;
  }
  // Android / other platforms
  final dir = await getApplicationDocumentsDirectory();
  return '${dir.path}/ravestreamer_settings.json';
}

// Serialize read–modify–write operations so an unrelated preference or room
// token cannot be lost when two changes are saved at nearly the same time.
Future<void> _pendingSettingsWrite = Future<void>.value();

Future<void> saveSettings(Map<String, dynamic> settings) {
  final snapshot = jsonEncode(settings);
  _pendingSettingsWrite = _pendingSettingsWrite.then((_) async {
    await _writeSettings(jsonDecode(snapshot) as Map<String, dynamic>);
  });
  return _pendingSettingsWrite;
}

Future<void> _writeSettings(Map<String, dynamic> settings) async {
  try {
    final path = await getSettingsPath();
    final file = File(path);
    if (!await file.parent.exists()) {
      await file.parent.create(recursive: true);
    }
    Map<String, dynamic> existing = {};
    if (await file.exists()) {
      try {
        existing = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      } catch (_) {}
    }
    existing.addAll(settings);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(jsonEncode(existing), flush: true);
    await temporary.rename(file.path);
  } catch (e) {
    debugPrint('Error saving settings: $e');
  }
}

Future<Map<String, dynamic>> loadSettings() async {
  await _pendingSettingsWrite;
  try {
    final path = await getSettingsPath();
    final file = File(path);
    if (await file.exists()) {
      final content = await file.readAsString();
      return jsonDecode(content) as Map<String, dynamic>;
    }
  } catch (e) {
    debugPrint('Error loading settings: $e');
  }
  return {};
}

Future<void> saveHostToken(String roomId, String token) async {
  globalHostTokens[roomId] = token;
  await saveSettings({'hostTokens': globalHostTokens});
}

Future<void> removeHostToken(String roomId) async {
  globalHostTokens.remove(roomId);
  await saveSettings({'hostTokens': globalHostTokens});
}
