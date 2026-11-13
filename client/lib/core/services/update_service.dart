import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

bool isTrustedUpdateUrl(String value) {
  final uri = Uri.tryParse(value);
  return uri != null &&
      uri.scheme == 'https' &&
      uri.host == 'github.com' &&
      uri.userInfo.isEmpty &&
      uri.port == 443 &&
      uri.path.startsWith('/stepa1235/RaveStreamerClient/releases/download/');
}

String globalAppVersion = "1.1.1";

bool isNewerVersion(String latest, String current) {
  try {
    final cleanLatest = latest.split('+')[0];
    final cleanCurrent = current.split('+')[0];
    List<int> parse(String v) => v
        .split('.')
        .map((e) => int.tryParse(e.replaceAll(RegExp(r'\D'), '')) ?? 0)
        .toList();
    final l = parse(cleanLatest);
    final c = parse(cleanCurrent);
    final maxLen = l.length > c.length ? l.length : c.length;
    for (int i = 0; i < maxLen; i++) {
      final lNum = i < l.length ? l[i] : 0;
      final cNum = i < c.length ? c[i] : 0;
      if (lNum > cNum) return true;
      if (lNum < cNum) return false;
    }
    if (latest.contains('+') && current.contains('+')) {
      final bLatest = int.tryParse(latest.split('+')[1]) ?? 0;
      final bCurrent = int.tryParse(current.split('+')[1]) ?? 0;
      if (bLatest > bCurrent) return true;
    }
  } catch (_) {}
  return false;
}

Future<void> downloadAndInstallUpdateWindows(
  BuildContext context,
  String downloadUrl,
  String version, {
  String locale = 'ru',
}) async {
  if (!isTrustedUpdateUrl(downloadUrl)) {
    throw ArgumentError('Untrusted update URL');
  }
  double progress = 0.0;
  StateSetter? dialogSetState;
  bool isDownloading = true;
  String statusText = locale == 'ru'
      ? 'Подключение к серверу...'
      : 'Connecting to server...';

  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (dialogCtx) => StatefulBuilder(
      builder: (context, setState) {
        dialogSetState = setState;
        return AlertDialog(
          backgroundColor: const Color(0xFF161426),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: Color(0xFF00F2FE), width: 1),
          ),
          title: Row(
            children: [
              if (isDownloading)
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Color(0xFF00F2FE),
                  ),
                )
              else
                const Icon(Icons.check_circle, color: Colors.green),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  locale == 'ru'
                      ? 'Обновление v$version'
                      : 'Auto-Updating v$version',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                statusText,
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: progress > 0 ? progress : null,
                  backgroundColor: Colors.white12,
                  color: const Color(0xFF00F2FE),
                  minHeight: 8,
                ),
              ),
            ],
          ),
        );
      },
    ),
  );

  try {
    final uri = Uri.parse(downloadUrl);
    final tempDir = await Directory.systemTemp.createTemp('luna-update-');
    final zipPath = '${tempDir.path}\\RaveStreamer_Update.zip';
    final zipFile = File(zipPath);
    if (await zipFile.exists()) await zipFile.delete();

    if (dialogSetState != null) {
      dialogSetState!(() {
        statusText = locale == 'ru'
            ? 'Скачивание обновления...'
            : 'Downloading update...';
      });
    }

    final client = http.Client();
    try {
      final req = http.Request('GET', uri);
      final res = await client.send(req).timeout(const Duration(seconds: 30));
      if (res.statusCode != 200)
        throw HttpException('Update HTTP ${res.statusCode}');
      final contentLength = res.contentLength ?? 0;

      int downloaded = 0;
      final sink = zipFile.openWrite();

      try {
        await res.stream.timeout(const Duration(seconds: 60)).forEach((chunk) {
          sink.add(chunk);
          downloaded += chunk.length;
          if (contentLength > 0 && dialogSetState != null) {
            dialogSetState!(() {
              progress = downloaded / contentLength;
              final mbReceived = (downloaded / (1024 * 1024)).toStringAsFixed(
                1,
              );
              final mbTotal = (contentLength / (1024 * 1024)).toStringAsFixed(
                1,
              );
              statusText = locale == 'ru'
                  ? 'Скачивание: $mbReceived MB / $mbTotal MB'
                  : 'Downloading: $mbReceived MB / $mbTotal MB';
            });
          }
        });
        await sink.flush();
      } finally {
        await sink.close();
      }

      if (downloaded < 100000 ||
          (contentLength > 0 && downloaded != contentLength)) {
        throw Exception(
          'Downloaded update is too small ($downloaded bytes). Possibly corrupted.',
        );
      }

      if (dialogSetState != null) {
        dialogSetState!(() {
          isDownloading = false;
          statusText = locale == 'ru'
              ? 'Установка... Приложение будет перезапущено.'
              : 'Installing... App will restart.';
        });
      }

      await Future.delayed(const Duration(milliseconds: 1000));

      final scriptPath = '${tempDir.path}\\update_rave.ps1';
      final currentExe = Platform.resolvedExecutable;
      final exeDir = File(currentExe).parent.path;
      final safeZip = zipPath.replaceAll("'", "''");
      final safeDest = exeDir.replaceAll("'", "''");
      final safeExe = currentExe.replaceAll("'", "''");

      final psScript =
          '''
Start-Sleep -Seconds 2
\$zip = '$safeZip'
\$dest = '$safeDest'
\$exe = '$safeExe'
for (\$i = 0; \$i -lt 10; \$i++) {
    try {
        Expand-Archive -LiteralPath \$zip -DestinationPath \$dest -Force -ErrorAction Stop
        break
    } catch {
        Start-Sleep -Seconds 1
    }
}
Remove-Item -LiteralPath \$zip -Force -ErrorAction SilentlyContinue
Start-Process -FilePath \$exe
''';
      await File(scriptPath).writeAsString(psScript);

      await Process.start('powershell', [
        '-ExecutionPolicy',
        'Bypass',
        '-WindowStyle',
        'Hidden',
        '-File',
        scriptPath,
      ], mode: ProcessStartMode.detached);

      exit(0);
    } finally {
      client.close();
    }
  } catch (e) {
    debugPrint('Auto-download error: $e');
    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
    try {
      await launchUrl(
        Uri.parse(downloadUrl),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {}
  }
}
