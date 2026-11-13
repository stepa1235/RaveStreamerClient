import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:media_kit/media_kit.dart' show MediaKit;
import 'package:webview_windows/webview_windows.dart';
import 'package:window_manager/window_manager.dart';
import 'package:local_notifier/local_notifier.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'core/theme/app_theme.dart';
import 'core/services/settings_service.dart';
import 'core/services/update_service.dart';
import 'screens/connection_page.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  try {
    PackageInfo packageInfo = await PackageInfo.fromPlatform();
    globalAppVersion = packageInfo.version;
  } catch (e) {
    debugPrint('Error getting package info: $e');
  }

  try {
    WakelockPlus.enable();
  } catch (e) {
    debugPrint('Wakelock error: $e');
  }

  if (Platform.isWindows) {
    await windowManager.ensureInitialized();
    await localNotifier.setup(appName: 'RaveStreamer');
    try {
      await WebviewController.initializeEnvironment(
        additionalArguments: '--autoplay-policy=no-user-gesture-required',
      );
      debugPrint('[webview] Environment initialized in main()');
    } catch (e) {
      debugPrint('[webview] Environment initialization failed in main(): $e');
    }
  }

  runApp(const RaveStreamerApp());
}

class RaveStreamerApp extends StatefulWidget {
  const RaveStreamerApp({super.key});

  @override
  State<RaveStreamerApp> createState() => _RaveStreamerAppState();
}

class _RaveStreamerAppState extends State<RaveStreamerApp> {
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  String _locale = 'ru';
  String _themeName = 'Dark';
  double _chatFontSize = 12.0;
  String _savedUsername = '';
  String _savedServerUrl = 'http://luna.lumigrid.ru:3000';
  bool _isLoading = true;

  // Cryptographically secure unique client ID (UUID v4)
  static String _generateSecureClientId() {
    final random = Random.secure();
    final values = List<int>.generate(16, (i) => random.nextInt(256));
    values[6] = (values[6] & 0x0f) | 0x40; // RFC 4122 v4
    values[8] = (values[8] & 0x3f) | 0x80; // RFC 4122 variant
    final hex = values.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20, 32)}';
  }

  String _clientId = '';

  @override
  void initState() {
    super.initState();
    _loadAllSettings();
  }

  Future<void> _loadAllSettings() async {
    final data = await loadSettings();
    if (!mounted) return;
    if (data.isNotEmpty) {
      setState(() {
        final locale = data['locale'];
        if (locale == 'ru' || locale == 'en') _locale = locale as String;
        final theme = data['themeName'];
        if (theme is String && appThemes.containsKey(theme)) _themeName = theme;
        final fontSize = data['chatFontSize'];
        if (fontSize is num && fontSize.isFinite) {
          _chatFontSize = fontSize.clamp(10.0, 24.0).toDouble();
        }
        if (data.containsKey('username')) _savedUsername = data['username'] as String;
        if (data.containsKey('clientId') && (data['clientId'] as String).isNotEmpty) {
          _clientId = data['clientId'] as String;
        }
        if (data.containsKey('hostTokens') && data['hostTokens'] is Map) {
          globalHostTokens = Map<String, String>.from(
            (data['hostTokens'] as Map).map((k, v) => MapEntry(k.toString(), v.toString())),
          );
        }
        if (data.containsKey('serverUrl')) {
          final sUrl = (data['serverUrl'] as String).trim();
          if (sUrl.isNotEmpty &&
              !sUrl.contains('loca.lt') &&
              !sUrl.contains('onrender.com') &&
              !sUrl.contains('localhost') &&
              !sUrl.contains('127.0.0.1')) {
            _savedServerUrl = sUrl;
          } else {
            _savedServerUrl = 'http://luna.lumigrid.ru:3000';
          }
        }
      });
    }

    if (_clientId.isEmpty) {
      _clientId = _generateSecureClientId();
      saveSettings({'clientId': _clientId});
    }

    _checkAppUpdates();

    setState(() {
      _isLoading = false;
    });
  }

  Future<void> _checkAppUpdates() async {
    try {
      final releaseRes = await http.get(
        Uri.parse('https://api.github.com/repos/stepa1235/RaveStreamerClient/releases/latest'),
        headers: {
          'User-Agent': 'LunaClient/1.0',
          'Accept': 'application/vnd.github.v3+json',
          'Cache-Control': 'no-cache',
        },
      ).timeout(const Duration(seconds: 5));

      if (releaseRes.statusCode == 200) {
        final releaseData = jsonDecode(releaseRes.body) as Map<String, dynamic>;
        final tagName = (releaseData['tag_name'] as String? ?? '').replaceAll('v', '');
        final assets = (releaseData['assets'] as List<dynamic>? ?? []);

        String winUrl = '';
        for (var asset in assets) {
          final name = asset['name'] as String? ?? '';
          final url = asset['browser_download_url'] as String? ?? '';
          if (name.endsWith('.zip')) winUrl = url;
        }

        if (tagName.isNotEmpty) {
          final jsonData = {
            'latest_version': tagName,
            'windows_url': winUrl.isNotEmpty
                ? winUrl
                : 'https://github.com/stepa1235/RaveStreamerClient/releases/latest/download/Luna-Windows.zip',
          };
          _checkForUpdates(jsonData);
        }
      }
    } catch (e) {
      debugPrint('GitHub Releases API update check error: $e');
    }
  }

  void _checkForUpdates(Map<String, dynamic> jsonData) {
    if (!jsonData.containsKey('latest_version')) return;
    final latestVersion = jsonData['latest_version'] as String;
    final String currentVersion = globalAppVersion;

    if (isNewerVersion(latestVersion, currentVersion)) {
      String downloadUrl = '';
      if (Platform.isAndroid) {
        downloadUrl = jsonData['android_url'] as String? ?? '';
      } else if (Platform.isWindows) {
        downloadUrl = jsonData['windows_url'] as String? ?? '';
      }

      if (downloadUrl.isEmpty) return;

      WidgetsBinding.instance.addPostFrameCallback((_) {
        _showUpdateDialog(latestVersion, downloadUrl);
      });
    }
  }

  void _showUpdateDialog(String version, String downloadUrl) {
    final activeTheme = appThemes[_themeName] ?? appThemes['Dark']!;
    final context = _navigatorKey.currentContext;
    if (context == null) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: activeTheme.cardColor,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16.0),
            side: BorderSide(color: activeTheme.primary.withOpacity(0.3), width: 1),
          ),
          title: Text(
            _locale == 'ru' ? 'Доступно обновление! 🚀' : 'Update Available! 🚀',
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          ),
          content: Text(
            _locale == 'ru'
                ? 'Доступна новая версия Luna v$version (текущая v$globalAppVersion).\nХотите обновиться?'
                : 'A new version of Luna v$version is available (current v$globalAppVersion).\nDo you want to update?',
            style: const TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(
                _locale == 'ru' ? 'Позже' : 'Later',
                style: const TextStyle(color: Colors.white54),
              ),
            ),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: activeTheme.primary,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8.0),
                ),
              ),
              icon: const Icon(Icons.downloading, size: 16),
              onPressed: () {
                Navigator.of(context).pop();
                downloadAndInstallUpdateWindows(context, downloadUrl, version, locale: _locale);
              },
              label: Text(
                _locale == 'ru' ? 'Авто-Обновление v$version' : 'Auto-Install v$version',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _saveAllSettings() async {
    await saveSettings({
      'locale': _locale,
      'themeName': _themeName,
      'chatFontSize': _chatFontSize,
      'username': _savedUsername,
      'serverUrl': _savedServerUrl,
    });
  }

  void _savePreferences(String locale, String theme, double fontSize) {
    setState(() {
      _locale = locale;
      _themeName = theme;
      _chatFontSize = fontSize;
    });
    unawaited(_saveAllSettings());
  }

  void _setLocale(String lang) {
    setState(() {
      _locale = lang;
    });
    _saveAllSettings();
  }

  void _setTheme(String theme) {
    setState(() {
      _themeName = theme;
    });
    _saveAllSettings();
  }

  void _setChatFontSize(double size) {
    setState(() {
      _chatFontSize = size;
    });
    _saveAllSettings();
  }

  void _setSavedConnection(String username, String serverUrl) {
    setState(() {
      _savedUsername = username;
      _savedServerUrl = serverUrl;
    });
    _saveAllSettings();
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: Center(
            child: CircularProgressIndicator(),
          ),
        ),
      );
    }

    final themeData = appThemes[_themeName] ?? appThemes['Dark']!;

    return MaterialApp(
      navigatorKey: _navigatorKey,
      title: 'RaveStreamer',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        primaryColor: themeData.primary,
        scaffoldBackgroundColor: themeData.scaffoldBackground,
        cardColor: themeData.cardColor,
        colorScheme: ColorScheme.dark(
          primary: themeData.primary,
          secondary: themeData.secondary,
          surface: themeData.cardColor,
        ),
        fontFamily: 'Roboto',
      ),
      home: ConnectionPage(
        locale: _locale,
        onLocaleChange: _setLocale,
        themeName: _themeName,
        onThemeChange: _setTheme,
        initialUsername: _savedUsername,
        initialServerUrl: _savedServerUrl,
        onSavedConnection: _setSavedConnection,
        onPreferencesSaved: _savePreferences,
        chatFontSize: _chatFontSize,
        onChatFontSizeChange: _setChatFontSize,
        clientId: _clientId,
      ),
    );
  }
}
