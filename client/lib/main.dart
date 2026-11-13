import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:luna_updates/luna_updates.dart';
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
    globalAppVersion = int.tryParse(packageInfo.buildNumber) == null
        ? packageInfo.version
        : '${packageInfo.version}+${packageInfo.buildNumber}';
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

  void _checkAppUpdates() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final updateContext = _navigatorKey.currentContext;
      if (mounted && updateContext != null && Platform.isWindows) {
        unawaited(checkLunaUpdate(
          updateContext,
          currentVersion: globalAppVersion,
          locale: _locale,
          platform: UpdatePlatform.windows,
          install: installWindowsUpdate,
        ));
      }
    });
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
