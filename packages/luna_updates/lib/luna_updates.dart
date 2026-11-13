import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

const _repository = 'stepa1235/RaveStreamerClient';
const _maximumSize = 1024 * 1024 * 1024;
final _versionPattern = RegExp(r'^v?(\d+)\.(\d+)\.(\d+)(?:\+(\d+))?$');
final _digestPattern = RegExp(r'^sha256:[a-f0-9]{64}$');

enum UpdatePlatform {
  windows('Luna-Windows.zip'),
  android('Luna.apk');

  const UpdatePlatform(this.fileName);
  final String fileName;
}

class LunaUpdate {
  const LunaUpdate._(
    this.version,
    this.platform,
    this.url,
    this.size,
    this.hash,
  );

  final String version;
  final UpdatePlatform platform;
  final Uri url;
  final int size;
  final String hash;

  static LunaUpdate? fromRelease(
    Map<String, dynamic> release,
    String currentVersion,
    UpdatePlatform platform,
  ) {
    final tag = release['tag_name'];
    if (release['draft'] == true || release['prerelease'] == true) return null;
    final current = _versionPattern.firstMatch(currentVersion);
    final latest = tag is String ? _versionPattern.firstMatch(tag) : null;
    if (current == null || latest == null) {
      throw const FormatException('Invalid Luna release version');
    }
    var comparison = 0;
    for (var i = 1; i <= 4 && comparison == 0; i++) {
      comparison = int.parse(
        latest[i] ?? '0',
      ).compareTo(int.parse(current[i] ?? '0'));
    }
    if (comparison <= 0) return null;

    final expectedUrl = Uri.https(
      'github.com',
      '/$_repository/releases/download/$tag/${platform.fileName}',
    );
    final assets = release['assets'];
    if (assets is List) {
      for (final asset in assets.whereType<Map>()) {
        if (asset['name'] != platform.fileName || asset['state'] != 'uploaded')
          continue;
        final size = asset['size'];
        final digest = asset['digest'];
        if (asset['browser_download_url'] == expectedUrl.toString() &&
            size is int &&
            size > 0 &&
            size <= _maximumSize &&
            digest is String &&
            _digestPattern.hasMatch(digest)) {
          final version = latest[0]!;
          return LunaUpdate._(
            version.startsWith('v') ? version.substring(1) : version,
            platform,
            expectedUrl,
            size,
            digest.substring(7),
          );
        }
      }
    }
    throw const FormatException(
      'Luna release is missing a verifiable platform file',
    );
  }
}

Future<LunaUpdate?> _latestUpdate(
  String current,
  UpdatePlatform platform,
) async {
  final client = http.Client();
  try {
    final response = await client
        .get(
          Uri.https('api.github.com', '/repos/$_repository/releases/latest'),
          headers: {'Accept': 'application/vnd.github+json'},
        )
        .timeout(const Duration(seconds: 12));
    if (response.statusCode == 404) return null;
    if (response.statusCode != 200) {
      throw HttpException('Release check returned HTTP ${response.statusCode}');
    }
    return LunaUpdate.fromRelease(
      jsonDecode(response.body) as Map<String, dynamic>,
      current,
      platform,
    );
  } finally {
    client.close();
  }
}

Future<void> downloadLunaUpdate(
  LunaUpdate update,
  File destination,
  ValueChanged<double> onProgress, {
  http.Client? client,
}) async {
  final transport = client ?? http.Client();
  try {
    var uri = update.url;
    for (var redirects = 0; redirects <= 5; redirects++) {
      final request = http.Request('GET', uri)..followRedirects = false;
      final response = await transport
          .send(request)
          .timeout(const Duration(seconds: 20));
      if (const [301, 302, 303, 307, 308].contains(response.statusCode)) {
        final location = response.headers['location'];
        if (location == null)
          throw const HttpException('Missing download redirect');
        uri = uri.resolve(location);
        if (uri.scheme != 'https' ||
            uri.port != 443 ||
            uri.userInfo.isNotEmpty ||
            !const {
              'github.com',
              'release-assets.githubusercontent.com',
              'objects.githubusercontent.com',
            }.contains(uri.host)) {
          throw const HttpException('Untrusted update redirect');
        }
        await response.stream
            .timeout(const Duration(seconds: 20))
            .drain<void>();
        continue;
      }
      if (response.statusCode != 200 ||
          (response.contentLength != null &&
              response.contentLength != update.size)) {
        throw const HttpException('Unexpected update response');
      }
      var received = 0;
      final output = await destination.open(mode: FileMode.write);
      try {
        await for (final chunk in response.stream.timeout(
          const Duration(seconds: 30),
        )) {
          received += chunk.length;
          if (received > update.size)
            throw const FormatException('Update is larger than expected');
          await output.writeFrom(chunk);
          onProgress(received / update.size);
        }
      } finally {
        await output.close();
      }
      if (received != update.size ||
          (await sha256.bind(destination.openRead()).single).toString() !=
              update.hash) {
        throw const FormatException('Update size or SHA-256 does not match');
      }
      return;
    }
    throw const HttpException('Too many update redirects');
  } catch (_) {
    try {
      if (await destination.exists()) await destination.delete();
    } on FileSystemException {
      // Preserve the original download failure.
    }
    rethrow;
  } finally {
    if (client == null) transport.close();
  }
}

bool _checking = false;

Future<void> checkLunaUpdate(
  BuildContext context, {
  required String currentVersion,
  required String locale,
  required UpdatePlatform platform,
  required Future<void> Function(File) install,
  Future<Directory> Function()? temporaryDirectory,
  bool manual = false,
}) async {
  if (_checking || !context.mounted) return;
  _checking = true;
  final ru = locale == 'ru';
  void message(String text) {
    if (context.mounted) {
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(text)));
    }
  }

  Directory? directory;
  var keepFiles = false;
  try {
    final update = await _latestUpdate(currentVersion, platform);
    if (!context.mounted) return;
    if (update == null) {
      if (manual)
        message(
          ru ? 'Установлена актуальная версия Luna.' : 'Luna is up to date.',
        );
      return;
    }
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          ru
              ? 'Доступна Luna ${update.version}'
              : 'Luna ${update.version} is available',
        ),
        content: Text(
          ru
              ? 'Скачать и установить обновление?'
              : 'Download and install the update?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(ru ? 'Позже' : 'Later'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(ru ? 'Обновить' : 'Update'),
          ),
        ],
      ),
    );
    if (accepted != true || !context.mounted) return;
    final parent =
        await (temporaryDirectory?.call() ??
            Future.value(Directory.systemTemp));
    directory = await parent.createTemp('luna-update-');
    if (!context.mounted) return;
    final file = File(
      '${directory.path}${Platform.pathSeparator}${platform.fileName}',
    );
    final progress = ValueNotifier<double?>(null);
    final navigator = Navigator.of(context, rootNavigator: true);
    final route = DialogRoute<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: Text(ru ? 'Загрузка обновления' : 'Downloading update'),
          content: ValueListenableBuilder<double?>(
            valueListenable: progress,
            builder: (_, value, _) => LinearProgressIndicator(value: value),
          ),
        ),
      ),
    );
    navigator.push(route);
    try {
      await downloadLunaUpdate(update, file, (value) {
        final percent = (value * 100).floor() / 100;
        progress.value = percent == 1 ? null : percent;
      });
      if (!context.mounted) return;
      await install(file);
      keepFiles = true;
    } finally {
      if (navigator.mounted && route.isActive) navigator.removeRoute(route);
      await route.completed;
      progress.dispose();
    }
  } catch (error) {
    debugPrint('Luna update failed: ${error.runtimeType}');
    if (manual || directory != null) {
      message(
        ru
            ? 'Не удалось обновить Luna. Попробуйте ещё раз.'
            : 'Could not update Luna. Please try again.',
      );
    }
  } finally {
    _checking = false;
    if (!keepFiles && directory != null) {
      try {
        await directory.delete(recursive: true);
      } on FileSystemException {
        // The download failure has already been handled.
      }
    }
  }
}
