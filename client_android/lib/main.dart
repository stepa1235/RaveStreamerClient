import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart' show MediaKit;
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'package:window_manager/window_manager.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart' hide Video;
import 'package:url_launcher/url_launcher.dart';
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';

const Map<String, Map<String, String>> _localizedValues = {
  'en': {
    'title': 'RaveStreamer',
    'subtitle': 'Synchronized Video Co-Watching',
    'nameLabel': 'Your Name (Max 15 chars)',
    'nameHint': 'Enter your name',
    'roomLabel': 'Room Name / ID (English only)',
    'roomHint': 'e.g. watchparty',
    'btnConnect': 'CONNECT & JOIN',
    'serverSettings': 'Server settings',
    'hideServerSettings': 'Hide Server settings',
    'serverUrlLabel': 'Server URL / IP address',
    'allFieldsRequired': 'All fields are required',
    'streamSettings': 'STREAM SETTINGS',
    'streamWebLink': 'Stream from Web Link',
    'webLinkDesc': 'Provide a direct URL to a video file or stream (MP4, MKV, HLS) to play it synchronously for everyone.',
    'pasteVideoUrl': 'Paste video URL...',
    'load': 'Load',
    'streamLocalFile': 'Stream Local PC File',
    'localFileDesc': 'Select any local video file to stream it to all connected users.',
    'chooseVideoFile': 'Choose Video File',
    'audience': 'AUDIENCE',
    'controls': 'Controls',
    'chat': 'Chat',
    'settings': 'Settings',
    'typeMessage': 'Type a message...',
    'video': 'Video: ',
    'openChat': 'Chat',
    'activeUsers': 'Active Users',
    'close': 'Close',
    'chatRoom': 'Chat Room',
    'kicked': 'You have been kicked from the room by the host.',
    'banned': 'You have been banned from this room by the host.',
    'bannedFromRoom': 'You are banned from this room.',
    'noVideo': 'No Video Loaded Yet',
    'emptyDesc': 'Enter a video link or pick a local video file from the right sidebar to start streaming synchronously.',
    'doubleClick': 'Double click / Rotate screen for hardware fullscreen',
    'room': 'Room: ',
    'hostLabel': 'Host',
    'kickTooltip': 'Kick this user',
    'banTooltip': 'Ban this user',
    'chatFontSize': 'Chat Font Size',
    'languageLabel': 'Language',
    'hostIps': 'Host IPs (for remote clients)',
    'themeLabel': 'App Theme',
    'themeDark': 'Dark',
    'themeCyan': 'Neon Cyan',
    'themeGold': 'Sunset Gold',
    'themePurple': 'Retro Purple',
  },
  'ru': {
    'title': 'RaveStreamer',
    'subtitle': 'Синхронный просмотр видео',
    'nameLabel': 'Ваше имя (макс. 15 симв.)',
    'nameHint': 'Введите ваше имя',
    'roomLabel': 'Имя комнаты (только англ.)',
    'roomHint': 'например, watchparty',
    'btnConnect': 'ПОДКЛЮЧИТЬСЯ',
    'serverSettings': 'Настройки сервера',
    'hideServerSettings': 'Скрыть настройки сервера',
    'serverUrlLabel': 'URL-адрес / IP сервера',
    'allFieldsRequired': 'Все поля обязательны',
    'streamSettings': 'НАСТРОЙКИ СТРИМА',
    'streamWebLink': 'Стрим по ссылке',
    'webLinkDesc': 'Вставьте прямую ссылку на видеофайл или поток (MP4, MKV, HLS) для совместного просмотра.',
    'pasteVideoUrl': 'Вставьте ссылку на видео...',
    'load': 'Загрузить',
    'streamLocalFile': 'Стрим файла с ПК',
    'localFileDesc': 'Выберите видеофайл на компьютере, чтобы запустить трансляцию всем участникам.',
    'chooseVideoFile': 'Выбрать видеофайл',
    'audience': 'ЗРИТЕЛИ',
    'controls': 'Управление',
    'chat': 'Чат',
    'settings': 'Настройки',
    'typeMessage': 'Напишите сообщение...',
    'video': 'Видео: ',
    'openChat': 'Чат',
    'activeUsers': 'Список участников',
    'close': 'Закрыть',
    'chatRoom': 'Чат комнаты',
    'kicked': 'Вы были исключены из комнаты хостом.',
    'banned': 'Вы были забанены в этой комнате хостом.',
    'bannedFromRoom': 'Вы забанены в этой комнате.',
    'noVideo': 'Видео не загружено',
    'emptyDesc': 'Вставьте веб-ссылку или выберите локальный видеофайл на панели справа для начала просмотра.',
    'doubleClick': 'Дважды кликните по видео для полноэкранного режима',
    'room': 'Комната: ',
    'hostLabel': 'Хост',
    'kickTooltip': 'Исключить пользователя',
    'banTooltip': 'Забанить пользователя',
    'chatFontSize': 'Размер шрифта чата',
    'languageLabel': 'Язык',
    'hostIps': 'IP-адреса хоста (для подключения)',
    'themeLabel': 'Тема приложения',
    'themeDark': 'Темная',
    'themeCyan': 'Неоновый циан',
    'themeGold': 'Золотой закат',
    'themePurple': 'Ретро пурпур',
  }
};

Future<String> _getSettingsPath() async {
  if (Platform.isWindows) {
    return 'C:\\RaveStreamer\\settings.json';
  }
  final dir = await getApplicationDocumentsDirectory();
  return '${dir.path}/ravestreamer_settings.json';
}

Future<void> saveSettings(Map<String, dynamic> settings) async {
  try {
    if (Platform.isWindows) {
      final dir = Directory('C:\\RaveStreamer');
      if (!await dir.exists()) await dir.create(recursive: true);
    }
    final path = await _getSettingsPath();
    final file = File(path);
    Map<String, dynamic> existing = {};
    if (await file.exists()) {
      try { existing = jsonDecode(await file.readAsString()) as Map<String, dynamic>; } catch(_) {}
    }
    existing.addAll(settings);
    await file.writeAsString(jsonEncode(existing));
  } catch (e) {
    debugPrint('Error saving settings: $e');
  }
}

Future<Map<String, dynamic>> loadSettings() async {
  try {
    final path = await _getSettingsPath();
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

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  runApp(const RaveStreamerApp());
}

class RaveStreamerTheme {
  final Color primary;
  final Color secondary;
  final Color scaffoldBackground;
  final Color cardColor;
  final List<Color> bgGradient;

  const RaveStreamerTheme({
    required this.primary,
    required this.secondary,
    required this.scaffoldBackground,
    required this.cardColor,
    required this.bgGradient,
  });
}

const Map<String, RaveStreamerTheme> _themes = {
  'Dark': RaveStreamerTheme(
    primary: Color(0xFF6C63FF),
    secondary: Color(0xFF00F2FE),
    scaffoldBackground: Color(0xFF0D0B14),
    cardColor: Color(0xFF161426),
    bgGradient: [Color(0xFF0F0C1B), Color(0xFF201A30), Color(0xFF0D0B14)],
  ),
  'Neon Cyan': RaveStreamerTheme(
    primary: Color(0xFF00F2FE),
    secondary: Color(0xFF9B51E0),
    scaffoldBackground: Color(0xFF071215),
    cardColor: Color(0xFF0C2126),
    bgGradient: [Color(0xFF08181C), Color(0xFF0B2C33), Color(0xFF071215)],
  ),
  'Sunset Gold': RaveStreamerTheme(
    primary: Color(0xFFFF9F43),
    secondary: Color(0xFFFF5252),
    scaffoldBackground: Color(0xFF1B0F0F),
    cardColor: Color(0xFF2E1616),
    bgGradient: [Color(0xFF1B0F0F), Color(0xFF381414), Color(0xFF120A0A)],
  ),
  'Retro Purple': RaveStreamerTheme(
    primary: Color(0xFFE84393),
    secondary: Color(0xFF6C63FF),
    scaffoldBackground: Color(0xFF130F1A),
    cardColor: Color(0xFF241635),
    bgGradient: [Color(0xFF130F1A), Color(0xFF2D144A), Color(0xFF0E0B13)],
  ),
};

class RaveStreamerApp extends StatefulWidget {
  const RaveStreamerApp({super.key});

  @override
  State<RaveStreamerApp> createState() => _RaveStreamerAppState();
}

class _RaveStreamerAppState extends State<RaveStreamerApp> {
  String _locale = 'ru';
  String _themeName = 'Dark';
  double _chatFontSize = 12.0;
  String _savedUsername = '';
  String _savedServerUrl = '';
  bool _isLoading = true;
  
  // Unique client ID generated in memory at app startup to resolve localhost username collision
  final String _clientId = 'client_${DateTime.now().microsecondsSinceEpoch}_${(1000 + (DateTime.now().millisecond % 9000))}';

  @override
  void initState() {
    super.initState();
    _loadAllSettings();
  }

  Future<void> _loadAllSettings() async {
    final data = await loadSettings();
    if (data.isNotEmpty) {
      setState(() {
        if (data.containsKey('locale')) _locale = data['locale'] as String;
        if (data.containsKey('themeName')) _themeName = data['themeName'] as String;
        if (data.containsKey('chatFontSize')) {
          _chatFontSize = (data['chatFontSize'] as num).toDouble();
        }
        if (data.containsKey('username')) _savedUsername = data['username'] as String;
      });
    }

    // Always fetch the latest server URL from GitHub Gist
    await _fetchServerUrlFromGist();

    setState(() {
      _isLoading = false;
    });
  }

  Future<void> _fetchServerUrlFromGist() async {
    bool updateChecked = false;
    final gistRawUrl =
        'https://gist.githubusercontent.com/stepa1235/0811a2ec6e74b06965de32f61643da5b/raw/ravestreamer.json?t=${DateTime.now().millisecondsSinceEpoch}';
    try {
      final response = await http.get(
        Uri.parse(gistRawUrl),
        headers: {'Cache-Control': 'no-cache', 'Pragma': 'no-cache'},
      ).timeout(const Duration(seconds: 8));

      if (response.statusCode == 200) {
        final jsonData = jsonDecode(response.body) as Map<String, dynamic>;
        if (jsonData.containsKey('url')) {
          final freshUrl = jsonData['url'] as String;
          debugPrint('Fetched server URL from Gist: $freshUrl');
          setState(() {
            _savedServerUrl = freshUrl;
          });

          // Check for app updates
          if (jsonData.containsKey('latest_version')) {
            _checkForUpdates(jsonData);
            updateChecked = true;
          }

          // Persist so it works offline next time
          await saveSettings({
            'locale': _locale,
            'themeName': _themeName,
            'chatFontSize': _chatFontSize,
            'username': _savedUsername,
            'serverUrl': freshUrl,
          });
        }
      }
    } catch (e) {
      debugPrint('Could not fetch Gist: $e');
    }

    // Fallback to saved URL from settings
    final data = await loadSettings();
    if (data.containsKey('serverUrl') && _savedServerUrl.isEmpty) {
      setState(() {
        _savedServerUrl = data['serverUrl'] as String;
      });
    }

    // Secondary update check via Render server /version endpoint if Gist didn't check
    final targetServerUrl = _savedServerUrl.isNotEmpty 
        ? _savedServerUrl 
        : 'https://ravestreamerserver.onrender.com';

    if (!updateChecked) {
      _fetchVersionFromServer(targetServerUrl);
    }
  }

  Future<void> _fetchVersionFromServer(String dummy, {bool verbose = false}) async {
    try {
      final gistRawUrl = 'https://gist.githubusercontent.com/stepa1235/0811a2ec6e74b06965de32f61643da5b/raw/ravestreamer.json?t=${DateTime.now().millisecondsSinceEpoch}';
      final res = await http.get(
        Uri.parse(gistRawUrl),
        headers: {'Cache-Control': 'no-cache'},
      ).timeout(const Duration(seconds: 6));

      if (res.statusCode == 200) {
        final jsonData = jsonDecode(res.body) as Map<String, dynamic>;
        _checkForUpdates(jsonData, verbose: verbose);
        return;
      }
    } catch (e) {
      debugPrint('Could not fetch version from Gist: $e');
    }
    if (verbose && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_locale == 'ru' ? 'Не удалось проверить обновления' : 'Could not check for updates'),
        ),
      );
    }
  }

  void _checkForUpdates(Map<String, dynamic> jsonData, {bool verbose = false}) {
    if (!jsonData.containsKey('latest_version')) return;
    final latestVersion = jsonData['latest_version'] as String;
    const String currentVersion = '1.1.4';

    if (latestVersion != currentVersion) {
      String downloadUrl = '';
      if (Platform.isAndroid) {
        downloadUrl = jsonData['android_url'] as String? ?? '';
      } else if (Platform.isWindows) {
        downloadUrl = jsonData['windows_url'] as String? ?? '';
      }

      if (downloadUrl.isEmpty) return;

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _showUpdateDialog(latestVersion, downloadUrl);
        }
      });
    } else if (verbose && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _locale == 'ru'
                ? 'У вас установлена последняя версия v$currentVersion! ✨'
                : 'You are using the latest version v$currentVersion! ✨',
          ),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  void _showUpdateDialog(String version, String downloadUrl) {
    final activeTheme = _themes[_themeName] ?? _themes['Dark']!;
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
            _locale == 'ru' ? 'Доступно обновление v$version! 🚀' : 'Update Available v$version! 🚀',
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _locale == 'ru'
                    ? 'Вышла новая версия RaveStreamer v$version.\nНажмите «Авто-установка» для скачивания внутри приложения!'
                    : 'A new version of RaveStreamer v$version is available.\nTap "Auto-Install" for direct in-app download!',
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 12),
              SelectableText(
                downloadUrl,
                style: const TextStyle(color: Color(0xFF00F2FE), fontSize: 11, decoration: TextDecoration.underline),
              ),
            ],
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
                _downloadAndInstallUpdate(downloadUrl, version);
              },
              label: Text(
                _locale == 'ru' ? 'Авто-установка v$version' : 'Auto-Install v$version',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _downloadAndInstallUpdate(String downloadUrl, String version) async {
    double progress = 0.0;
    StateSetter? dialogSetState;
    bool isDownloading = true;
    String statusText = _locale == 'ru' ? 'Подключение к серверу...' : 'Connecting to server...';

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
                  const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF00F2FE)))
                else
                  const Icon(Icons.check_circle, color: Colors.green),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _locale == 'ru' ? 'Автообновление v$version' : 'Auto-Updating v$version',
                    style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(statusText, style: const TextStyle(color: Colors.white70, fontSize: 13)),
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
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    '${(progress * 100).toStringAsFixed(1)}%',
                    style: const TextStyle(color: Color(0xFF00F2FE), fontSize: 13, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );

    try {
      final req = http.Request('GET', Uri.parse(downloadUrl));
      final res = await http.Client().send(req);
      final total = res.contentLength ?? 0;
      int received = 0;

      final tempDir = Directory.systemTemp;
      final apkPath = '${tempDir.path}/app-release.apk';
      final apkFile = File(apkPath);
      if (await apkFile.exists()) await apkFile.delete();

      final sink = apkFile.openWrite();

      await res.stream.forEach((chunk) {
        received += chunk.length;
        sink.add(chunk);
        if (total > 0 && dialogSetState != null) {
          dialogSetState!(() {
            progress = received / total;
            final mbReceived = (received / (1024 * 1024)).toStringAsFixed(1);
            final mbTotal = (total / (1024 * 1024)).toStringAsFixed(1);
            statusText = _locale == 'ru'
                ? 'Загрузка: $mbReceived MB / $mbTotal MB'
                : 'Downloading: $mbReceived MB / $mbTotal MB';
          });
        }
      });

      await sink.close();

      if (dialogSetState != null) {
        dialogSetState!(() {
          isDownloading = false;
          statusText = _locale == 'ru' ? 'Скачано! Запуск установки...' : 'Downloaded! Launching installer...';
        });
      }

      await Future.delayed(const Duration(milliseconds: 500));
      if (mounted) Navigator.of(context).pop();

      // Launch installer
      final fileUri = Uri.file(apkPath);
      final webUri = Uri.parse(downloadUrl);
      if (await canLaunchUrl(fileUri)) {
        await launchUrl(fileUri);
      } else {
        await launchUrl(webUri, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      debugPrint('Auto-download error: $e');
      if (mounted) Navigator.of(context).pop();
      try {
        await launchUrl(Uri.parse(downloadUrl), mode: LaunchMode.externalApplication);
      } catch (_) {}
    }
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

    final themeData = _themes[_themeName] ?? _themes['Dark']!;

    return MaterialApp(
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
        chatFontSize: _chatFontSize,
        onChatFontSizeChange: _setChatFontSize,
        clientId: _clientId,
      ),
    );
  }
}

// First Screen: Connect to Server & Join Room
class ConnectionPage extends StatefulWidget {
  final String locale;
  final ValueChanged<String> onLocaleChange;
  final String themeName;
  final ValueChanged<String> onThemeChange;
  final String initialUsername;
  final String initialServerUrl;
  final Function(String, String) onSavedConnection;
  final double chatFontSize;
  final ValueChanged<double> onChatFontSizeChange;
  final String clientId;

  const ConnectionPage({
    super.key,
    required this.locale,
    required this.onLocaleChange,
    required this.themeName,
    required this.onThemeChange,
    required this.initialUsername,
    required this.initialServerUrl,
    required this.onSavedConnection,
    required this.chatFontSize,
    required this.onChatFontSizeChange,
    required this.clientId,
  });

  @override
  State<ConnectionPage> createState() => _ConnectionPageState();
}

class _ConnectionPageState extends State<ConnectionPage> {
  late final TextEditingController _serverController;
  late final TextEditingController _usernameController;
  final _roomController = TextEditingController(text: 'lobby');
  final _passwordController = TextEditingController();
  bool _isConnecting = false;
  bool _isPrivateRoom = false;
  String? _errorMessage;


  @override
  void initState() {
    super.initState();
    _serverController = TextEditingController(
      text: widget.initialServerUrl.isNotEmpty ? widget.initialServerUrl : 'https://ravestreamer-stepa-server.loca.lt',
    );
    _usernameController = TextEditingController(
      text: widget.initialUsername.isNotEmpty ? widget.initialUsername : 'User_${(1000 + (DateTime.now().millisecond % 9000))}',
    );
  }

  @override
  void dispose() {
    _serverController.dispose();
    _usernameController.dispose();
    _roomController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  String _loc(String key) {
    return _localizedValues[widget.locale]?[key] ?? key;
  }

  Future<void> _connectAndJoin() async {
    final username = _usernameController.text.trim();
    final roomId = _roomController.text.trim();

    if (username.isEmpty || roomId.isEmpty) {
      setState(() {
        _errorMessage = _loc('allFieldsRequired');
      });
      return;
    }

    setState(() {
      _isConnecting = true;
      _errorMessage = null;
    });

    String serverUrl = _serverController.text.trim();

    // Re-fetch Gist URL right when clicking to guarantee the freshest address is used
    try {
      final gistRawUrl =
          'https://gist.githubusercontent.com/stepa1235/0811a2ec6e74b06965de32f61643da5b/raw/ravestreamer.json?t=${DateTime.now().millisecondsSinceEpoch}';
      final response = await http.get(Uri.parse(gistRawUrl)).timeout(const Duration(seconds: 3));
      if (response.statusCode == 200) {
        final jsonData = jsonDecode(response.body) as Map<String, dynamic>;
        if (jsonData.containsKey('url')) {
          serverUrl = jsonData['url'] as String;
          _serverController.text = serverUrl;
        }
      }
    } catch (e) {
      debugPrint('Could not refresh Gist URL, using cached URL: $e');
    }

    // Save connection settings immediately so nickname persists
    widget.onSavedConnection(username, serverUrl);

    if (!mounted) return;
    setState(() {
      _isConnecting = false;
    });

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => RoomPage(
          serverUrl: serverUrl,
          username: username,
          roomId: roomId,
          password: _isPrivateRoom ? _passwordController.text.trim() : null,
          locale: widget.locale,
          onLocaleChange: widget.onLocaleChange,
          themeName: widget.themeName,
          onThemeChange: widget.onThemeChange,
          chatFontSize: widget.chatFontSize,
          onChatFontSizeChange: widget.onChatFontSizeChange,
          clientId: widget.clientId,
        ),
      ),
    );
  }

  void _showGlobalSettingsDialog(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return Container(
          decoration: const BoxDecoration(
            color: Color(0xFF161426),
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 20,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.settings, color: Color(0xFF00F2FE)),
                        const SizedBox(width: 8),
                        Text(
                          widget.locale == 'ru' ? 'Настройки приложения ⚙️' : 'App Settings ⚙️',
                          style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white54),
                      onPressed: () => Navigator.of(ctx).pop(),
                    ),
                  ],
                ),
                const Divider(color: Colors.white12),
                const SizedBox(height: 12),

                // Language Card
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: Colors.white.withOpacity(0.05), borderRadius: BorderRadius.circular(12)),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(widget.locale == 'ru' ? 'Язык / Language' : 'Language', style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
                      Row(
                        children: [
                          ChoiceChip(
                            label: const Text('RU'),
                            selected: widget.locale == 'ru',
                            onSelected: (_) => widget.onLocaleChange('ru'),
                            selectedColor: const Color(0xFF6C63FF),
                          ),
                          const SizedBox(width: 8),
                          ChoiceChip(
                            label: const Text('EN'),
                            selected: widget.locale == 'en',
                            onSelected: (_) => widget.onLocaleChange('en'),
                            selectedColor: const Color(0xFF6C63FF),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),

                // Theme Card
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: Colors.white.withOpacity(0.05), borderRadius: BorderRadius.circular(12)),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(widget.locale == 'ru' ? 'Тема оформления' : 'App Theme', style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        children: [
                          'Dark', 'Neon Cyan', 'Sunset Gold', 'Retro Purple'
                        ].map((t) => ChoiceChip(
                          label: Text(t),
                          selected: widget.themeName == t,
                          onSelected: (_) => widget.onThemeChange(t),
                          selectedColor: const Color(0xFF00F2FE).withOpacity(0.4),
                        )).toList(),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),

                // Chat Font Size Card
                StatefulBuilder(
                  builder: (context, setSt) {
                    return Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(color: Colors.white.withOpacity(0.05), borderRadius: BorderRadius.circular(12)),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(widget.locale == 'ru' ? 'Шрифт чата' : 'Chat Font Size', style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
                              Text('${widget.chatFontSize.toInt()} px', style: const TextStyle(color: Color(0xFF00F2FE), fontSize: 12)),
                            ],
                          ),
                          Slider(
                            min: 10.0,
                            max: 24.0,
                            divisions: 14,
                            value: widget.chatFontSize,
                            activeColor: const Color(0xFF6C63FF),
                            onChanged: (val) {
                              setSt(() {});
                              widget.onChatFontSizeChange(val);
                            },
                          ),
                        ],
                      ),
                    );
                  },
                ),
                const SizedBox(height: 12),

                // Auto-Update Card
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: Colors.white.withOpacity(0.05), borderRadius: BorderRadius.circular(12)),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.system_update, size: 16, color: Color(0xFF00F2FE)),
                          SizedBox(width: 8),
                          Text('Автообновление (v1.1.4)', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
                        ],
                      ),
                      ElevatedButton(
                        onPressed: () {
                          Navigator.of(ctx).pop();
                          _fetchVersionFromServer(_serverController.text.trim(), verbose: true);
                        },
                        style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00F2FE).withOpacity(0.2), foregroundColor: const Color(0xFF00F2FE)),
                        child: Text(widget.locale == 'ru' ? 'Проверить' : 'Check'),
                      ),
                    ],
                  ),
                ),
                // Server Address Input removed on Android
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _fetchVersionFromServer(String dummy, {bool verbose = false}) async {
    try {
      final gistRawUrl = 'https://gist.githubusercontent.com/stepa1235/0811a2ec6e74b06965de32f61643da5b/raw/ravestreamer.json?t=${DateTime.now().millisecondsSinceEpoch}';
      final res = await http.get(
        Uri.parse(gistRawUrl),
        headers: {'Cache-Control': 'no-cache'},
      ).timeout(const Duration(seconds: 6));

      if (res.statusCode == 200) {
        final jsonData = jsonDecode(res.body) as Map<String, dynamic>;
        _checkForUpdates(jsonData, verbose: verbose);
        return;
      }
    } catch (e) {
      debugPrint('Could not fetch version from Gist: $e');
    }
    if (verbose && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(widget.locale == 'ru' ? 'Не удалось проверить обновления' : 'Could not check for updates'),
        ),
      );
    }
  }

  bool _isNewerVersion(String latest, String current) {
    try {
      List<int> parse(String v) => v.split('.').map((e) => int.tryParse(e.replaceAll(RegExp(r'\D'), '')) ?? 0).toList();
      final l = parse(latest);
      final c = parse(current);
      final maxLen = l.length > c.length ? l.length : c.length;
      for (int i = 0; i < maxLen; i++) {
        final lNum = i < l.length ? l[i] : 0;
        final cNum = i < c.length ? c[i] : 0;
        if (lNum > cNum) return true;
        if (lNum < cNum) return false;
      }
    } catch (_) {}
    return false;
  }

  void _checkForUpdates(Map<String, dynamic> jsonData, {bool verbose = false}) {
    if (!jsonData.containsKey('latest_version')) return;
    final latestVersion = jsonData['latest_version'] as String;
    const String currentVersion = '1.1.4';

    if (_isNewerVersion(latestVersion, currentVersion)) {
      String downloadUrl = '';
      if (Platform.isAndroid) {
        downloadUrl = jsonData['android_url'] as String? ?? '';
      } else if (Platform.isWindows) {
        downloadUrl = jsonData['windows_url'] as String? ?? '';
      }

      if (downloadUrl.isEmpty) return;

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _showUpdateDialog(latestVersion, downloadUrl);
        }
      });
    } else if (verbose && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            widget.locale == 'ru'
                ? 'У вас установлена последняя версия v$currentVersion! ✨'
                : 'You are using the latest version v$currentVersion! ✨',
          ),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  void _showUpdateDialog(String version, String downloadUrl) {
    final activeTheme = _themes[widget.themeName] ?? _themes['Dark']!;
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
            widget.locale == 'ru' ? 'Доступно обновление v$version! 🚀' : 'Update Available v$version! 🚀',
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.locale == 'ru'
                    ? 'Вышла новая версия RaveStreamer v$version.\nНажмите «Авто-установка» для скачивания внутри приложения!'
                    : 'A new version of RaveStreamer v$version is available.\nTap "Auto-Install" for direct in-app download!',
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 12),
              SelectableText(
                downloadUrl,
                style: const TextStyle(color: Color(0xFF00F2FE), fontSize: 11, decoration: TextDecoration.underline),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(
                widget.locale == 'ru' ? 'Позже' : 'Later',
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
                _downloadAndInstallUpdate(downloadUrl, version);
              },
              label: Text(
                widget.locale == 'ru' ? 'Авто-установка v$version' : 'Auto-Install v$version',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _downloadAndInstallUpdate(String downloadUrl, String version) async {
    double progress = 0.0;
    StateSetter? dialogSetState;
    bool isDownloading = true;
    String statusText = widget.locale == 'ru' ? 'Подключение к серверу...' : 'Connecting to server...';

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
                  const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF00F2FE)))
                else
                  const Icon(Icons.check_circle, color: Colors.green),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    widget.locale == 'ru' ? 'Автообновление v$version' : 'Auto-Updating v$version',
                    style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(statusText, style: const TextStyle(color: Colors.white70, fontSize: 13)),
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
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    '${(progress * 100).toStringAsFixed(1)}%',
                    style: const TextStyle(color: Color(0xFF00F2FE), fontSize: 13, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );

    try {
      final req = http.Request('GET', Uri.parse(downloadUrl));
      final res = await http.Client().send(req);
      final total = res.contentLength ?? 0;
      int received = 0;

      final tempDir = Directory.systemTemp;
      final apkPath = '${tempDir.path}/app-release.apk';
      final apkFile = File(apkPath);
      if (await apkFile.exists()) await apkFile.delete();

      final sink = apkFile.openWrite();

      await res.stream.forEach((chunk) {
        received += chunk.length;
        sink.add(chunk);
        if (total > 0 && dialogSetState != null) {
          dialogSetState!(() {
            progress = received / total;
            final mbReceived = (received / (1024 * 1024)).toStringAsFixed(1);
            final mbTotal = (total / (1024 * 1024)).toStringAsFixed(1);
            statusText = widget.locale == 'ru'
                ? 'Загрузка: $mbReceived MB / $mbTotal MB'
                : 'Downloading: $mbReceived MB / $mbTotal MB';
          });
        }
      });

      await sink.close();

      if (dialogSetState != null) {
        dialogSetState!(() {
          isDownloading = false;
          statusText = widget.locale == 'ru' ? 'Скачано! Запуск установки...' : 'Downloaded! Launching installer...';
        });
      }

      await Future.delayed(const Duration(milliseconds: 500));
      if (mounted) Navigator.of(context).pop();

      // Launch installer
      final result = await OpenFilex.open(apkPath, type: "application/vnd.android.package-archive");
      debugPrint('OpenFilex result: ${result.type} ${result.message}');
      if (result.type != ResultType.done) {
        await launchUrl(Uri.parse(downloadUrl), mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      debugPrint('Auto-download error: $e');
      if (mounted) Navigator.of(context).pop();
      try {
        await launchUrl(Uri.parse(downloadUrl), mode: LaunchMode.externalApplication);
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    final themeData = _themes[widget.themeName] ?? _themes['Dark']!;
    return Scaffold(
      body: Stack(
        children: [
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: themeData.bgGradient,
              ),
            ),
            child: Center(
              child: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.all(24.0),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 450),
                    child: Container(
                      padding: const EdgeInsets.all(32.0),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.03),
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(
                          color: Colors.white.withOpacity(0.08),
                          width: 1.5,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.3),
                            blurRadius: 20,
                            spreadRadius: 2,
                          )
                        ],
                      ),
                      child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Top Action Bar: Settings & Language
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF6C63FF).withOpacity(0.2),
                              foregroundColor: const Color(0xFF00F2FE),
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                                side: const BorderSide(color: Color(0xFF00F2FE), width: 0.8),
                              ),
                            ),
                            icon: const Icon(Icons.settings, size: 16),
                            label: Text(
                              widget.locale == 'ru' ? 'Настройки ⚙️' : 'Settings ⚙️',
                              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                            ),
                            onPressed: () => _showGlobalSettingsDialog(context),
                          ),
                          DropdownButtonHideUnderline(
                            child: DropdownButton<String>(
                              value: widget.locale,
                              dropdownColor: const Color(0xFF161426),
                              style: const TextStyle(fontSize: 12, color: Colors.white),
                              icon: const Icon(Icons.language, size: 16, color: Color(0xFF00F2FE)),
                              items: const [
                                DropdownMenuItem(value: 'ru', child: Text('RU')),
                                DropdownMenuItem(value: 'en', child: Text('EN')),
                              ],
                              onChanged: (lang) {
                                if (lang != null) widget.onLocaleChange(lang);
                              },
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),

                      // Header Logo
                      Center(
                        child: Column(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                color: const Color(0xFF6C63FF).withOpacity(0.15),
                                shape: BoxShape.circle,
                                boxShadow: [
                                  BoxShadow(
                                    color: const Color(0xFF6C63FF).withOpacity(0.3),
                                    blurRadius: 15,
                                    spreadRadius: 1,
                                  )
                                ],
                              ),
                              child: const Icon(
                                Icons.play_circle_filled,
                                size: 56,
                                color: Color(0xFF00F2FE),
                              ),
                            ),
                            const SizedBox(height: 16),
                            Text(
                              _loc('title'),
                              style: const TextStyle(
                                fontSize: 32,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 1.5,
                                color: Colors.white,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              _loc('subtitle'),
                              style: TextStyle(
                                fontSize: 14,
                                color: Colors.white.withOpacity(0.5),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 32),



                      // Username Input (Max 15 characters to fit in the audience window)
                      _buildTextField(
                        controller: _usernameController,
                        label: _loc('nameLabel'),
                        icon: Icons.person_outline,
                        hint: _loc('nameHint'),
                        inputFormatters: [
                          LengthLimitingTextInputFormatter(15),
                        ],
                      ),
                      const SizedBox(height: 16),

                      // Room ID Input (Regex filters out non-english and special symbols)
                      _buildTextField(
                        controller: _roomController,
                        label: _loc('roomLabel'),
                        icon: Icons.vpn_key_outlined,
                        hint: _loc('roomHint'),
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(RegExp(r'[a-zA-Z0-9]')),
                        ],
                      ),
                      const SizedBox(height: 16),
                      
                      // Private Room Switch
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              Icon(
                                _isPrivateRoom ? Icons.lock_outline : Icons.lock_open,
                                size: 18,
                                color: _isPrivateRoom ? const Color(0xFF00F2FE) : Colors.white54,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                widget.locale == 'ru' ? 'Приватная комната' : 'Private Room',
                                style: TextStyle(
                                  color: _isPrivateRoom ? Colors.white : Colors.white54,
                                  fontSize: 14,
                                ),
                              ),
                            ],
                          ),
                          Switch(
                            value: _isPrivateRoom,
                            activeColor: const Color(0xFF00F2FE),
                            onChanged: (val) {
                              setState(() {
                                _isPrivateRoom = val;
                              });
                            },
                          ),
                        ],
                      ),
                      if (_isPrivateRoom) ...[
                        const SizedBox(height: 12),
                        _buildTextField(
                          controller: _passwordController,
                          label: widget.locale == 'ru' ? 'ПАРОЛЬ КОМНАТЫ' : 'ROOM PASSWORD',
                          icon: Icons.password,
                          hint: widget.locale == 'ru' ? 'Введите пароль' : 'Enter password',
                        ),
                      ],
                      const SizedBox(height: 24),


                      // Error message container
                      if (_errorMessage != null) ...[
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 12),
                          decoration: BoxDecoration(
                            color: Colors.red.withOpacity(0.15),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: Colors.red.withOpacity(0.3)),
                          ),
                          child: Text(
                            _errorMessage!,
                            style: const TextStyle(color: Colors.redAccent, fontSize: 13),
                          ),
                        ),
                        const SizedBox(height: 20),
                      ],

                      // Join Button
                      ElevatedButton(
                        onPressed: _isConnecting ? null : _connectAndJoin,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF6C63FF),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                          elevation: 8,
                          shadowColor: const Color(0xFF6C63FF).withOpacity(0.4),
                        ),
                        child: _isConnecting
                            ? const SizedBox(
                                height: 20,
                                width: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.5,
                                  color: Colors.white,
                                ),
                              )
                            : Text(
                                _loc('btnConnect'),
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 1.2,
                                ),
                              ),
                      ),

                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
          Positioned(
            left: 16,
            bottom: 16,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.4),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white.withOpacity(0.1)),
              ),
              child: Text(
                'v1.1.4',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.6),
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    required String hint,
    List<TextInputFormatter>? inputFormatters,
  }) {
    return TextField(
      controller: controller,
      inputFormatters: inputFormatters,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: Icon(icon, color: const Color(0xFF6C63FF).withOpacity(0.7)),
        filled: true,
        fillColor: Colors.white.withOpacity(0.02),
        labelStyle: TextStyle(color: Colors.white.withOpacity(0.6)),
        hintStyle: TextStyle(color: Colors.white.withOpacity(0.3)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: Colors.white.withOpacity(0.08)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Color(0xFF6C63FF), width: 1.5),
        ),
        contentPadding: const EdgeInsets.symmetric(vertical: 16),
      ),
    );
  }
}

// Second Screen: RaveStreamer Player & Control Room
class RoomPage extends StatefulWidget {
  final String serverUrl;
  final String username;
  final String roomId;
  final String? password;
  final String locale;
  final ValueChanged<String> onLocaleChange;
  final String themeName;
  final ValueChanged<String> onThemeChange;
  final double chatFontSize;
  final ValueChanged<double> onChatFontSizeChange;
  final String clientId;

  const RoomPage({
    super.key,
    required this.serverUrl,
    required this.username,
    required this.roomId,
    this.password,
    required this.locale,
    required this.onLocaleChange,
    required this.themeName,
    required this.onThemeChange,
    required this.chatFontSize,
    required this.onChatFontSizeChange,
    required this.clientId,
  });

  @override
  State<RoomPage> createState() => _RoomPageState();
}

class _RoomPageState extends State<RoomPage> {
  late IO.Socket _socket;
  WebviewPlayer? _mkPlayer;
  bool _playerReady = false; // becomes true once player is initialized

  // App states
  bool _isConnected = false;
  List<dynamic> _users = [];
  String _currentVideoUrl = '';
  String _currentVideoName = 'No Video Loaded';
  bool _isIncomingUpdate = false;
  bool _isDisposed = false;
  bool _isSidebarVisible = true;
  List<dynamic> _queue = [];
  String _preferredQuality = 'Auto';
  List<dynamic> _translators = [];
  String _currentPageUrl = ''; // original lordfilm/site URL (for translator switching)
  
  // Tabs, Chat & Localization States
  int _selectedTab = 0; // 0 = Controls, 1 = Chat, 2 = Settings
  final List<Map<String, String>> _messages = []; // [{ 'sender': 'Name', 'text': 'Hello', 'time': '12:34' }]
  int _unreadMessages = 0;
  late double _chatFontSize; // Default chat font size
  late String _locale;
  
  final _urlInputController = TextEditingController();
  final _localPathController = TextEditingController();
  final _chatInputController = TextEditingController();
  final _chatScrollController = ScrollController();
  final _chatFocusNode = FocusNode(); // FocusNode to keep keyboard open
  
  Timer? _syncTimer;
  bool _isPlayerVisible = false;
  bool _showControls = true;
  Timer? _controlsTimer;

  String _loc(String key) {
    return _localizedValues[_locale]?[key] ?? key;
  }

  @override
  void initState() {
    super.initState();
    _locale = widget.locale;
    _chatFontSize = widget.chatFontSize;
    _selectedTab = 1; // Default to Chat tab for convenient Rave-like experience
    // Pre-create player ONCE
    final player = WebviewPlayer();
    player.initialize().then((_) {
      if (mounted && !_isDisposed) {
        setState(() {
          _mkPlayer = player;
          _playerReady = true;
        });
      }
    });
    player.stream.completed.listen((completed) {
      if (!completed || _isDisposed || !mounted) return;
      final isHost = _users.isNotEmpty && _users[0]['id'] == _socket.id;
      if (isHost) _socket.emit('skip-video', {'roomId': widget.roomId});
    });
    player.stream.error.listen((err) {
      debugPrint('[webview] ERROR: $err');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Player error: $err'), backgroundColor: Colors.red, duration: const Duration(seconds: 5)),
        );
      }
    });
    player.stream.playing.listen((_) { if (mounted) setState(() {}); });
    player.stream.position.listen((_) { if (mounted) setState(() {}); });
    player.stream.duration.listen((_) { if (mounted) setState(() {}); });
    _initSocket();
    _syncTimer = Timer.periodic(const Duration(seconds: 3), (timer) {
      _sendPeriodicSync();
    });
  }

  @override
  void dispose() {
    _isDisposed = true;
    _syncTimer?.cancel();
    _controlsTimer?.cancel();
    _mkPlayer?.dispose();
    _socket.disconnect();
    _socket.dispose();
    _urlInputController.dispose();
    _localPathController.dispose();
    _chatInputController.dispose();
    _chatScrollController.dispose();
    _chatFocusNode.dispose();
    super.dispose();
  }

  // Socket.io initialization and handlers
  void _initSocket() {
    _socket = IO.io(widget.serverUrl, IO.OptionBuilder()
      .setTransports(['websocket'])
      .disableAutoConnect()
      .setExtraHeaders({'bypass-tunnel-reminder': 'true'})
      .build()
    );

    _socket.connect();

    _socket.onConnect((_) {
      if (_isDisposed || !mounted) return;
      setState(() {
        _isConnected = true;
      });
      // Join the specified room
      _socket.emit('join-room', {
        'roomId': widget.roomId,
        'username': widget.username,
        if (widget.password != null && widget.password!.isNotEmpty) 'password': widget.password,
    });

    _socket.on('room-error', (msg) {
      if (!mounted || _isDisposed) return;
      
      bool isWrongPassword = false;
      String errorText = msg.toString();
      
      if (msg is Map) {
        if (msg['type'] == 'WRONG_PASSWORD') isWrongPassword = true;
        errorText = msg['message']?.toString() ?? 'Error';
      } else if (errorText.contains('пароль') || errorText.contains('password')) {
        isWrongPassword = true;
      }

      if (isWrongPassword) {
        final pwController = TextEditingController();
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF161426),
            title: Text(widget.locale == 'ru' ? 'Приватная комната' : 'Private Room', style: const TextStyle(color: Color(0xFF00F2FE))),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(widget.locale == 'ru' ? 'Введите правильный пароль:' : 'Enter correct password:', style: const TextStyle(color: Colors.white)),
                const SizedBox(height: 12),
                TextField(
                  controller: pwController,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: Colors.black26,
                    hintText: widget.locale == 'ru' ? 'Пароль' : 'Password',
                    hintStyle: const TextStyle(color: Colors.white54),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  _isDisposed = true;
                  _socket.disconnect();
                  if (mounted) Navigator.pop(context);
                },
                child: Text(widget.locale == 'ru' ? 'Отмена' : 'Cancel', style: const TextStyle(color: Colors.white54)),
              ),
              ElevatedButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  _socket.emit('join-room', {
                    'roomId': widget.roomId,
                    'username': widget.username,
                    'password': pwController.text.trim(),
                  });
                },
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00F2FE)),
                child: Text(widget.locale == 'ru' ? 'Войти' : 'Join', style: const TextStyle(color: Colors.black)),
              ),
            ],
          ),
        );
        return;
      }

      _isDisposed = true;
      _socket.disconnect();
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF161426),
          title: Text(widget.locale == 'ru' ? 'Ошибка' : 'Error', style: const TextStyle(color: Colors.redAccent)),
          content: Text(errorText, style: const TextStyle(color: Colors.white)),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                if (mounted) Navigator.pop(context);
              },
              child: const Text('OK', style: TextStyle(color: Color(0xFF00F2FE))),
            ),
          ],
        ),
      );
    });

    _socket.onDisconnect((_) {
      if (_isDisposed || !mounted) return;
      setState(() {
        _isConnected = false;
        _users = [];
      });
    });

    // Handle user list updates
    _socket.on('room-users', (data) {
      if (_isDisposed || !mounted) return;
      setState(() {
        _users = data;
      });
    });

    // Handle initial room state when joining
    _socket.on('room-state', (data) {
      if (_isDisposed || !mounted) return;
      final videoUrl = data['videoUrl'] as String;
      final videoName = data['videoName'] as String;
      final isPlaying = data['isPlaying'] as bool;
      final calculatedTime = (data['calculatedTime'] as num).toDouble();
      final queueData = data['queue'] as List<dynamic>? ?? [];
      final headers = data['headers'] as Map<String, dynamic>?;

      setState(() {
        _queue = queueData;
      });

      if (videoUrl.isNotEmpty) {
        _setupVideoPlayer(videoUrl, videoName, startPlaying: isPlaying, startSeconds: calculatedTime, headers: headers);
      }
    });

    // Handle video change event
    _socket.on('video-changed', (data) {
      if (_isDisposed || !mounted) return;
      final videoUrl = data['videoUrl'] as String;
      final videoName = data['videoName'] as String;
      final headers = data['headers'] as Map<String, dynamic>?;
      
      _setupVideoPlayer(videoUrl, videoName, startPlaying: true, headers: headers);
    });

    // Handle queue updates event
    _socket.on('queue-updated', (data) {
      if (_isDisposed || !mounted) return;
      setState(() {
        _queue = data['queue'] as List<dynamic>;
      });
    });

    // Handle remote play event
    _socket.on('played', (data) {
      if (_isDisposed || !mounted) return;
      final time = (data['time'] as num).toDouble();
      _handleRemotePlay(time);
    });

    // Handle remote pause event
    _socket.on('paused', (data) {
      if (_isDisposed || !mounted) return;
      final time = (data['time'] as num).toDouble();
      _handleRemotePause(time);
    });

    // Handle remote seek event
    _socket.on('seeked', (data) {
      if (_isDisposed || !mounted) return;
      final time = (data['time'] as num).toDouble();
      _handleRemoteSeek(time);
    });

    // Handle continuous background sync
    _socket.on('sync-state-broadcast', (data) {
      if (_isDisposed || !mounted) return;
      final isPlaying = data['isPlaying'] as bool;
      final currentTime = (data['currentTime'] as num).toDouble();
      _handlePeriodicSync(isPlaying, currentTime);
    });

    // Handle Chat Message Broadcast
    _socket.on('chat-msg', (data) {
      if (_isDisposed || !mounted) return;
      setState(() {
        _messages.add({
          'clientId': (data['clientId'] ?? '') as String,
          'sender': data['username'] as String,
          'text': data['text'] as String,
          'time': (data['timestamp'] ?? data['time'] ?? '') as String,
        });
        if (_selectedTab != 1) {
          _unreadMessages++;
        }
      });
      // Scroll to bottom
      Timer(const Duration(milliseconds: 100), () {
        if (_chatScrollController.hasClients) {
          _chatScrollController.animateTo(
            _chatScrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
          );
        }
      });
    });

    // Handle Chat History (e.g. on rejoin/reconnect)
    _socket.on('chat-history', (data) {
      if (_isDisposed || !mounted) return;
      final history = data as List<dynamic>;
      setState(() {
        _messages.clear();
        for (final msg in history) {
          _messages.add({
            'clientId': (msg['clientId'] ?? '') as String,
            'sender': msg['username'] as String,
            'text': msg['text'] as String,
            'time': (msg['timestamp'] ?? msg['time'] ?? '') as String,
          });
        }
      });
      // Scroll to bottom
      Timer(const Duration(milliseconds: 150), () {
        if (_chatScrollController.hasClients) {
          _chatScrollController.jumpTo(_chatScrollController.position.maxScrollExtent);
        }
      });
    });

    // Handle Kicked from host
    _socket.on('kicked', (_) {
      if (_isDisposed || !mounted) return;
      _socket.disconnect();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_loc('kicked')),
          backgroundColor: Colors.red,
        ),
      );
      Navigator.of(context).popUntil((route) => route.isFirst);
    });

    // Handle Kicked & Banned from host
    _socket.on('kicked-and-banned', (_) {
      if (_isDisposed || !mounted) return;
      _socket.disconnect();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_loc('banned')),
          backgroundColor: Colors.red,
        ),
      );
      Navigator.of(context).popUntil((route) => route.isFirst);
    });

    // Handle join error (e.g. banned)
    _socket.on('join-error', (data) {
      if (_isDisposed || !mounted) return;
      final errorMsg = data as String;
      _socket.disconnect();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(errorMsg),
          backgroundColor: Colors.red,
        ),
      );
      Navigator.of(context).pop(); // Go back to connection page
    });
  }

  // Send chat message
  void _sendChatMessage() {
    final text = _chatInputController.text.trim();
    if (text.isEmpty) return;
    _socket.emit('chat-msg', {
      'roomId': widget.roomId,
      'username': widget.username,
      'text': text,
      'clientId': widget.clientId,
    });
    _chatInputController.clear();
    _chatFocusNode.requestFocus(); // Re-focus chat text field instantly
  }

  // Kick user (Host only)
  void _kickUser(String targetSocketId) {
    _socket.emit('kick-user', {
      'roomId': widget.roomId,
      'targetSocketId': targetSocketId,
    });
  }

  // Ban user (Host only)
  void _banUser(String targetSocketId) {
    _socket.emit('ban-user', {
      'roomId': widget.roomId,
      'targetSocketId': targetSocketId,
    });
  }

  // Set up video player with a specific URL (uses media_kit which supports HLS natively)
  Future<void> _setupVideoPlayer(String url, String name, {bool startPlaying = false, double startSeconds = 0.0, Map<String, dynamic>? headers}) async {
    if (_isDisposed || !mounted) return;

    setState(() {
      _currentVideoUrl = url;
      _currentVideoName = name;
      _isPlayerVisible = true;
    });

    String playUrl = url;
    final lowercaseUrl = url.toLowerCase();
    final isYouTube = lowercaseUrl.contains('youtube.com') || lowercaseUrl.contains('youtu.be');

    // Build HTTP headers for media_kit
    final Map<String, String> playerHeaders = {
      'bypass-tunnel-reminder': 'true',
      'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1',
    };

    if (isYouTube) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_locale == 'ru' ? 'Извлечение качества $_preferredQuality...' : 'Extracting $_preferredQuality...'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
      final streamUrl = await getYoutubeStreamUrl(url);
      if (streamUrl != null) {
        playUrl = streamUrl;
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(_locale == 'ru' ? 'Локальное извлечение не удалось...' : 'Local extraction failed...'),
              duration: const Duration(seconds: 2),
            ),
          );
        }
      }
    } else if (lowercaseUrl.startsWith('http') &&
               !url.contains('/video?path=') &&
               !url.contains('/proxy/') &&
               !lowercaseUrl.contains('.mp4') &&
               !lowercaseUrl.contains('.m3u8') &&
               !lowercaseUrl.contains('.mkv') &&
               !lowercaseUrl.contains('.webm') &&
               !lowercaseUrl.contains('vkuser') &&
               !lowercaseUrl.contains('vk-cdn')) {
      // Non-YouTube web link: extract via server
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_locale == 'ru' ? 'Извлечение видеопотока...' : 'Extracting video stream...'),
            duration: const Duration(seconds: 5),
          ),
        );
      }
      try {
        final extractUri = Uri.parse('${widget.serverUrl}/extract?url=${Uri.encodeComponent(url)}');
        final response = await http.get(
          extractUri,
          headers: {'bypass-tunnel-reminder': 'true'},
        ).timeout(const Duration(seconds: 120));

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body) as Map<String, dynamic>;
          if (data['success'] == true && data['url'] != null) {
            final rawUrl = data['url'] as String;
            playUrl = rawUrl.startsWith('/') ? '${widget.serverUrl}$rawUrl' : rawUrl;
            
            // Pass cookies + referer so libmpv can fetch HLS segments from CDN
            final cookies = data['cookies']?.toString() ?? '';
            if (cookies.isNotEmpty) {
              playerHeaders['Cookie'] = cookies;
            }
            try {
              final cdnUri = Uri.parse(playUrl);
              playerHeaders['Referer'] = '${cdnUri.scheme}://${cdnUri.host}/';
              playerHeaders['Origin'] = '${cdnUri.scheme}://${cdnUri.host}';
            } catch (_) {}

            if (mounted) {
              setState(() {
                _translators = data['translators'] as List<dynamic>? ?? [];
                _currentPageUrl = url;
              });
            }
          } else {
            throw Exception(data['error'] ?? 'Extraction failed');
          }
        } else {
          throw Exception('Server error ${response.statusCode}');
        }
      } catch (e) {
        debugPrint('Extraction failed: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Extraction failed: $e'), backgroundColor: Colors.red),
          );
        }
        return;
      }
    }

    // Merge any extra headers
    if (headers != null) {
      headers.forEach((key, value) {
        playerHeaders[key] = value.toString();
      });
    }

    if (_isDisposed || !mounted) return;
    debugPrint('[media_kit] Opening: $playUrl');

    final player = _mkPlayer;
    if (player == null) return;

    try {
      // Reuse the pre-created player — Webview is always in the tree.
      await player.open(
        Media(playUrl, httpHeaders: playerHeaders),
        play: false,
      );

      if (_isDisposed || !mounted) return;

      if (startSeconds > 0.0) {
        await player.seek(Duration(milliseconds: (startSeconds * 1000).toInt()));
      }
      if (startPlaying) {
        await player.play();
      }
    } catch (e) {
      if (!mounted) return;
      debugPrint('Error opening media: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to load video: $e'), backgroundColor: Colors.red),
      );
    }
  }


  Future<String?> getYoutubeStreamUrl(String youtubeUrl) async {
    String videoIdStr = youtubeUrl;
    try {
      final uri = Uri.parse(youtubeUrl);
      if (uri.host.contains('youtu.be')) {
        videoIdStr = uri.pathSegments.isNotEmpty ? uri.pathSegments.first : youtubeUrl;
      } else if (uri.queryParameters.containsKey('v')) {
        videoIdStr = uri.queryParameters['v']!;
      } else if (uri.pathSegments.contains('embed')) {
        final idx = uri.pathSegments.indexOf('embed');
        if (idx + 1 < uri.pathSegments.length) videoIdStr = uri.pathSegments[idx + 1];
      }
    } catch (_) {}

    final embedUrl = 'https://www.youtube.com/embed/$videoIdStr?autoplay=1&enablejsapi=1';
    debugPrint('[youtube] Converted YouTube URL to Embed: $embedUrl');
    return embedUrl;
  }

  // Send video change event to server
  void _changeVideo(String url, String name) async {
    if (url.trim().isEmpty) return;
    
    String finalUrl = url.trim();
    String finalName = name.trim().isEmpty ? 'Web Stream' : name.trim();
    
    final lowercaseUrl = url.toLowerCase();
    final isWebLink = lowercaseUrl.startsWith('http://') || lowercaseUrl.startsWith('https://');
    
    Map<String, dynamic>? finalHeaders;

    if (isWebLink &&
        !url.contains('/video?path=') &&
        !url.contains('/proxy/') &&
        !lowercaseUrl.contains('.mp4') &&
        !lowercaseUrl.contains('.m3u8') &&
        !lowercaseUrl.contains('.mkv') &&
        !lowercaseUrl.contains('.webm')) {
      final isYouTube = lowercaseUrl.contains('youtube.com') || lowercaseUrl.contains('youtu.be');
      
      if (isYouTube) {
        // Broadcast the original YouTube link so clients can choose their own quality!
        finalUrl = url;
        finalName = name.trim().isEmpty ? 'YouTube Video' : name.trim();
      } else {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_locale == 'ru' 
              ? 'Извлечение видеопотока с сервера...' 
              : 'Extracting video stream from server...'),
            duration: const Duration(seconds: 5),
          ),
        );
        
        try {
          final extractUri = Uri.parse('${widget.serverUrl}/extract?url=${Uri.encodeComponent(url)}');
          final response = await http.get(
            extractUri,
            headers: {'bypass-tunnel-reminder': 'true'},
          ).timeout(const Duration(seconds: 120));
          
          if (response.statusCode == 200) {
            final data = jsonDecode(response.body) as Map<String, dynamic>;
            if (data['success'] == true && data['url'] != null) {
              // URL is already a /proxy/hls URL — no auth headers needed from client
              final rawUrl = data['url'] as String;
              // If it's a relative proxy path, make it absolute with the server URL
              if (rawUrl.startsWith('/')) {
                finalUrl = '${widget.serverUrl}$rawUrl';
              } else {
                finalUrl = rawUrl;
              }
              finalName = data['title'] as String? ?? 'Web Stream';
              finalHeaders = null; // No special headers needed - proxy handles it
              if (mounted) {
                setState(() {
                  _translators = data['translators'] as List<dynamic>? ?? [];
                  _currentPageUrl = url;
                });
              }
            } else {
              throw Exception(data['error'] ?? 'Unknown extraction error');
            }
          } else {
            throw Exception('Server status ${response.statusCode}');
          }
        } catch (e) {
          debugPrint('Server-side extraction failed: $e');
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(_locale == 'ru' 
                ? 'Не удалось извлечь видеопоток: $e' 
                : 'Failed to extract stream: $e'),
              backgroundColor: Colors.red,
            ),
          );
          return;
        }
      }
    }
    
    _socket.emit('video-change', {
      'roomId': widget.roomId,
      'videoUrl': finalUrl,
      'videoName': finalName,
      'headers': finalHeaders,
    });
  }

  void _addToQueue(String url, String name) async {
    if (url.trim().isEmpty) return;
    
    String finalUrl = url.trim();
    String finalName = name.trim().isEmpty ? 'Web Stream' : name.trim();
    
    final lowercaseUrl = url.toLowerCase();
    final isWebLink = lowercaseUrl.startsWith('http://') || lowercaseUrl.startsWith('https://');
    
    Map<String, dynamic>? finalHeaders;

    if (isWebLink &&
        !url.contains('/video?path=') &&
        !url.contains('/proxy/') &&
        !lowercaseUrl.contains('.mp4') &&
        !lowercaseUrl.contains('.m3u8') &&
        !lowercaseUrl.contains('.mkv') &&
        !lowercaseUrl.contains('.webm')) {
      final isYouTube = lowercaseUrl.contains('youtube.com') || lowercaseUrl.contains('youtu.be');
      
      if (isYouTube) {
        // Queue the original YouTube link so clients can extract their own quality later!
        finalUrl = url;
        finalName = name.trim().isEmpty ? 'YouTube Video' : name.trim();
      } else {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_locale == 'ru' ? 'Извлечение видеопотока для очереди...' : 'Extracting video stream for queue...'),
            duration: const Duration(seconds: 4),
          ),
        );
        
        try {
          final extractUri = Uri.parse('${widget.serverUrl}/extract?url=${Uri.encodeComponent(url)}');
          final response = await http.get(
            extractUri,
            headers: {'bypass-tunnel-reminder': 'true'},
          ).timeout(const Duration(seconds: 120));
          
          if (response.statusCode == 200) {
            final data = jsonDecode(response.body) as Map<String, dynamic>;
            if (data['success'] == true && data['url'] != null) {
              final rawUrl = data['url'] as String;
              if (rawUrl.startsWith('/')) {
                finalUrl = '${widget.serverUrl}$rawUrl';
              } else {
                finalUrl = rawUrl;
              }
              finalName = data['title'] as String? ?? 'Web Stream';
              finalHeaders = null; // proxy handles it
              if (mounted) {
                setState(() {
                  _translators = data['translators'] as List<dynamic>? ?? [];
                  _currentPageUrl = url;
                });
              }
            } else {
              throw Exception(data['error'] ?? 'Unknown extraction error');
            }
          } else {
            throw Exception('Server status ${response.statusCode}');
          }
        } catch (e) {
          debugPrint('Extraction failed for queue: $e');
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(_locale == 'ru' ? 'Ошибка извлечения: $e' : 'Extraction error: $e'),
              backgroundColor: Colors.red,
            ),
          );
          return;
        }
      }
    }
    
    _socket.emit('add-to-queue', {
      'roomId': widget.roomId,
      'videoUrl': finalUrl,
      'videoName': finalName,
      'headers': finalHeaders,
    });

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(_locale == 'ru' ? 'Видео добавлено в очередь!' : 'Video added to queue!'),
        backgroundColor: Colors.green,
      ),
    );
  }

  void _removeFromQueue(int index) {
    _socket.emit('remove-from-queue', {
      'roomId': widget.roomId,
      'index': index,
    });
  }

  Future<void> _switchDubbing(int translatorIndex) async {
    if (_currentPageUrl.isEmpty) return;
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_locale == 'ru' ? 'Переключение озвучки...' : 'Switching dubbing...'),
          duration: const Duration(seconds: 3),
        ),
      );
    }
    try {
      final uri = Uri.parse(
        '${widget.serverUrl}/extract-translator?url=${Uri.encodeComponent(_currentPageUrl)}&index=$translatorIndex',
      );
      final response = await http.get(uri, headers: {'bypass-tunnel-reminder': 'true'})
          .timeout(const Duration(seconds: 120));

      if (!mounted) return;
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        if (data['success'] == true && data['url'] != null) {
          String videoUrl = data['url'] as String;
          if (videoUrl.startsWith('/')) videoUrl = '${widget.serverUrl}$videoUrl';
          await _setupVideoPlayer(videoUrl, _currentVideoName, startPlaying: true);
          // Sync to room
          _socket.emit('change-video', {
            'roomId': widget.roomId,
            'videoUrl': videoUrl,
            'videoName': _currentVideoName,
          });
        } else {
          throw Exception(data['error'] ?? 'Unknown error');
        }
      } else {
        throw Exception('Server returned ${response.statusCode}');
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_locale == 'ru' ? 'Ошибка переключения: $e' : 'Switch error: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }


  void _skipVideo() {
    _socket.emit('skip-video', {
      'roomId': widget.roomId,
    });
  }

  // Handle local user control events and broadcast them
  void _localPlay() {
    if (_mkPlayer == null) return;
    _mkPlayer!.play();
    _socket.emit('play', {
      'roomId': widget.roomId,
      'time': _mkPlayer!.state.position.inMilliseconds / 1000.0,
    });
  }

  void _localPause() {
    if (_mkPlayer == null) return;
    _mkPlayer!.pause();
    _socket.emit('pause', {
      'roomId': widget.roomId,
      'time': _mkPlayer!.state.position.inMilliseconds / 1000.0,
    });
  }

  void _localSeek(double seconds) {
    if (_mkPlayer == null) return;
    _isIncomingUpdate = true;
    _mkPlayer!.seek(Duration(milliseconds: (seconds * 1000).toInt())).then((_) {
      _isIncomingUpdate = false;
    });
    _socket.emit('seek', {
      'roomId': widget.roomId,
      'time': seconds,
    });
  }

  // Host sends its current playing details so others can synchronize to it
  void _sendPeriodicSync() {
    if (_mkPlayer == null || !_isConnected) return;
    
    final isHost = _users.isNotEmpty && _users[0]['id'] == _socket.id;
    if (isHost) {
      _socket.emit('sync-state', {
        'roomId': widget.roomId,
        'isPlaying': _mkPlayer!.state.playing,
        'currentTime': _mkPlayer!.state.position.inMilliseconds / 1000.0,
      });
    }
  }

  // Receive play command from server
  void _handleRemotePlay(double serverSeconds) {
    if (_mkPlayer == null) return;
    _isIncomingUpdate = true;
    _mkPlayer!.seek(Duration(milliseconds: (serverSeconds * 1000).toInt())).then((_) {
      _mkPlayer!.play().then((_) {
        _isIncomingUpdate = false;
      });
    });
  }

  // Receive pause command from server
  void _handleRemotePause(double serverSeconds) {
    if (_mkPlayer == null) return;
    _isIncomingUpdate = true;
    _mkPlayer!.seek(Duration(milliseconds: (serverSeconds * 1000).toInt())).then((_) {
      _mkPlayer!.pause().then((_) {
        _isIncomingUpdate = false;
      });
    });
  }

  // Receive seek command from server
  void _handleRemoteSeek(double serverSeconds) {
    if (_mkPlayer == null) return;
    _isIncomingUpdate = true;
    _mkPlayer!.seek(Duration(milliseconds: (serverSeconds * 1000).toInt())).then((_) {
      _isIncomingUpdate = false;
    });
  }

  // Sync client playback with host if they drift too far
  void _handlePeriodicSync(bool serverIsPlaying, double serverSeconds) {
    if (_mkPlayer == null || _isIncomingUpdate) return;

    final isHost = _users.isNotEmpty && _users[0]['id'] == _socket.id;
    if (isHost) return;

    final localSeconds = _mkPlayer!.state.position.inMilliseconds / 1000.0;
    final drift = (localSeconds - serverSeconds).abs();

    _isIncomingUpdate = true;

    final duration = _mkPlayer!.state.duration;
    final position = _mkPlayer!.state.position;
    final isAtEnd = duration.inMilliseconds > 0 && position.inMilliseconds >= duration.inMilliseconds - 100;

    if (serverIsPlaying && !_mkPlayer!.state.playing && !isAtEnd) {
      _mkPlayer!.play();
    } else if (!serverIsPlaying && _mkPlayer!.state.playing) {
      _mkPlayer!.pause();
    }

    if (drift > 1.5) {
      _mkPlayer!.seek(Duration(milliseconds: (serverSeconds * 1000).toInt())).then((_) {
        _isIncomingUpdate = false;
      });
    } else {
      _isIncomingUpdate = false;
    }
  }

  bool _isUploading = false;

  Future<void> _uploadAndStreamLocalFile(String filePath, String fileName) async {
    final file = File(filePath);
    if (!await file.exists()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Selected file does not exist.'), backgroundColor: Colors.red),
      );
      return;
    }

    final totalSize = await file.length();
    
    setState(() {
      _isUploading = true;
    });

    final progressNotifier = ValueNotifier<double>(0.0);
    final statusNotifier = ValueNotifier<String>(_locale == 'ru' ? 'Подготовка к загрузке...' : 'Preparing upload...');

    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF100E1C),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(
            children: [
              const Icon(Icons.cloud_upload_outlined, color: Color(0xFF00F2FE)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _locale == 'ru' ? 'Загрузка файла' : 'Uploading File',
                  style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                fileName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: Colors.white.withOpacity(0.8), fontSize: 13),
              ),
              const SizedBox(height: 16),
              ValueListenableBuilder<double>(
                valueListenable: progressNotifier,
                builder: (context, progress, child) {
                  return Column(
                    children: [
                      LinearProgressIndicator(
                        value: progress,
                        backgroundColor: Colors.white12,
                        valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF00F2FE)),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            '${(progress * 100).toStringAsFixed(1)}%',
                            style: const TextStyle(color: Color(0xFF00F2FE), fontSize: 12, fontWeight: FontWeight.bold),
                          ),
                          Text(
                            '${(totalSize / (1024 * 1024)).toStringAsFixed(1)} MB',
                            style: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 12),
                          ),
                        ],
                      ),
                    ],
                  );
                }
              ),
              const SizedBox(height: 8),
              ValueListenableBuilder<String>(
                valueListenable: statusNotifier,
                builder: (context, status, child) {
                  return Text(
                    status,
                    style: TextStyle(color: Colors.white.withOpacity(0.6), fontSize: 11),
                    textAlign: TextAlign.center,
                  );
                }
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                _isUploading = false;
                Navigator.of(context).pop();
              },
              child: Text(
                _locale == 'ru' ? 'Отмена' : 'Cancel',
                style: const TextStyle(color: Colors.redAccent),
              ),
            ),
          ],
        );
      },
    );

    try {
      final uploadUri = Uri.parse('${widget.serverUrl}/upload?roomId=${Uri.encodeComponent(widget.roomId)}');
      final request = MultipartRequestWithProgress(
        'POST',
        uploadUri,
        onProgress: (bytesTransferred, totalBytes) {
          if (!_isUploading) return;
          final progress = totalBytes > 0 ? bytesTransferred / totalBytes : 0.0;
          progressNotifier.value = progress;
          statusNotifier.value = _locale == 'ru'
              ? 'Загружено: ${(bytesTransferred / (1024 * 1024)).toStringAsFixed(1)} MB из ${(totalBytes / (1024 * 1024)).toStringAsFixed(1)} MB'
              : 'Uploaded: ${(bytesTransferred / (1024 * 1024)).toStringAsFixed(1)} MB of ${(totalBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
        },
      );
      
      request.headers['bypass-tunnel-reminder'] = 'true';

      request.files.add(await http.MultipartFile.fromPath('video', filePath));
      
      final streamedResponse = await request.send();
      final response = await http.Response.fromStream(streamedResponse);
      
      if (!_isUploading) return;
      
      if (!mounted) return;
      Navigator.of(context).pop();
      setState(() {
        _isUploading = false;
      });

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        if (data['success'] == true) {
          final relativePath = data['path'] as String;
          final streamUrl = '${widget.serverUrl}/video?path=${Uri.encodeComponent(relativePath)}';
          
          _changeVideo(streamUrl, fileName);
          
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(_locale == 'ru' ? 'Видео успешно загружено!' : 'Video uploaded successfully!'),
              backgroundColor: Colors.green,
            ),
          );
        } else {
          throw Exception(data['error'] ?? 'Unknown upload error');
        }
      } else {
        throw Exception('Server returned status code ${response.statusCode}');
      }

    } catch (e) {
      if (_isUploading) {
        if (mounted) {
          Navigator.of(context).pop();
        }
      }
      setState(() {
        _isUploading = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Upload failed: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  // File picker handler: chooses local file and uploads it to Node server
  Future<void> _pickLocalFile() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.video,
        allowMultiple: false,
      );

      if (result != null && result.files.single.path != null) {
        final filePath = result.files.single.path!;
        final fileName = result.files.single.name;
        
        _uploadAndStreamLocalFile(filePath, fileName);
      }
    } catch (e) {
      if (!mounted) return;
      debugPrint('Error picking file: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('File picker error: $e'), backgroundColor: Colors.red),
      );
    }
  }

  void _triggerControlsVisibility() {
    setState(() {
      _showControls = true;
    });
    _controlsTimer?.cancel();
    _controlsTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && (_mkPlayer?.state.playing ?? false)) {
        setState(() {
          _showControls = false;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final isDesktop = screenWidth > 800;

    return Scaffold(
      appBar: _showControls || !(_mkPlayer?.state.playing ?? false)
          ? AppBar(
        title: Row(
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _isConnected ? Colors.greenAccent : Colors.redAccent,
              ),
            ),
            const SizedBox(width: 10),
            Text(
              '${_loc('room')}${widget.roomId}',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.08),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                'v1.1.4',
                style: TextStyle(fontSize: 10, color: Colors.white.withOpacity(0.5), fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        backgroundColor: const Color(0xFF0F0C1B),
        elevation: 0,
        actions: [
          IconButton(
            icon: Icon(_isSidebarVisible ? Icons.menu_open : Icons.menu),
            onPressed: () {
              setState(() {
                _isSidebarVisible = !_isSidebarVisible;
              });
            },
            tooltip: _isSidebarVisible ? 'Hide Controls' : 'Show Controls',
          ),
          IconButton(
            icon: const Icon(Icons.people_outline),
            onPressed: () => _showUsersDialog(),
            tooltip: _loc('activeUsers'),
          ),
        ],
      )
          : PreferredSize(preferredSize: Size.zero, child: const SizedBox.shrink()),
      body: GestureDetector(
        onTap: _triggerControlsVisibility,
        behavior: HitTestBehavior.opaque,
        child: Container(
        color: const Color(0xFF0D0B14),
        child: (isDesktop || MediaQuery.of(context).orientation == Orientation.landscape)
            ? Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: _buildMainContent(),
                  ),
                  if (_isSidebarVisible && (_showControls || !(_mkPlayer?.state.playing ?? false))) ...[
                    VerticalDivider(
                      color: Colors.white.withOpacity(0.05),
                      width: 1,
                    ),
                    Container(
                      width: 340, // Sidebar width for desktop / landscape
                      color: const Color(0xFF100E1C),
                      child: _buildControlSidebar(),
                    ),
                  ],
                ],
              )
            : Column(
                children: [
                  if (_isSidebarVisible) ...[
                    AspectRatio(
                      aspectRatio: 16 / 9,
                      child: _buildMainContent(),
                    ),
                    Expanded(
                      child: Container(
                        color: const Color(0xFF100E1C),
                        child: _buildControlSidebar(),
                      ),
                    ),
                  ] else ...[
                    Expanded(
                      child: _buildMainContent(),
                    ),
                  ],
                ],
              ),
      ),
      ),
    );
  }

  Widget _buildMainContent() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Video display container
        Expanded(
          child: Container(
            color: Colors.black,
            child: Stack(
              fit: StackFit.expand,
              children: [
                GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _triggerControlsVisibility,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        _playerReady && _mkPlayer != null && _mkPlayer!.isInitialized
                            ? WebViewWidget(controller: _mkPlayer!.controller)
                            : const Center(
                                child: CircularProgressIndicator(
                                  valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF6C63FF)),
                                ),
                              ),
                        AnimatedOpacity(
                          opacity: _showControls ? 1.0 : 0.0,
                          duration: const Duration(milliseconds: 300),
                          child: _buildVideoControlsOverlay(),
                        ),
                        // Show placeholder when no video is loaded
                        if (_currentVideoUrl.isEmpty)
                          _buildEmptyState(),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.video_library_outlined,
              size: 72,
              color: Colors.white.withOpacity(0.2),
            ),
            const SizedBox(height: 16),
            Text(
              _loc('noVideo'),
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              _loc('emptyDesc'),
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVideoControlsOverlay() {
    if (_mkPlayer == null) return const SizedBox.shrink();

    final position = _mkPlayer!.state.position;
    final duration = _mkPlayer!.state.duration;
    final isPlaying = _mkPlayer!.state.playing;
    final volume = _mkPlayer!.state.volume / 100.0; // media_kit volume is 0-100
    final isMeHost = _users.isNotEmpty && _users[0]['id'] == _socket.id;

    String formatDuration(Duration d) {
      String twoDigits(int n) => n.toString().padLeft(2, "0");
      String twoDigitMinutes = twoDigits(d.inMinutes.remainder(60));
      String twoDigitSeconds = twoDigits(d.inSeconds.remainder(60));
      if (d.inHours > 0) {
        return "${twoDigits(d.inHours)}:$twoDigitMinutes:$twoDigitSeconds";
      }
      return "$twoDigitMinutes:$twoDigitSeconds";
    }

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.black.withOpacity(0.5),
            Colors.transparent,
            Colors.transparent,
            Colors.black.withOpacity(0.7),
          ],
        ),
      ),
      child: Column(
        children: [
          // Upper details
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _currentVideoName,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      shadows: [Shadow(blurRadius: 4, color: Colors.black)],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFF6C63FF).withOpacity(0.8),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Text(
                    'SYNCED',
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
          ),
          const Spacer(),
          // Bottom controls
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Progress Slider
                  Row(
                    children: [
                      Text(
                        formatDuration(position),
                        style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: isMeHost
                            ? SliderTheme(
                                data: SliderTheme.of(context).copyWith(
                                  activeTrackColor: const Color(0xFF00F2FE),
                                  inactiveTrackColor: Colors.white24,
                                  thumbColor: const Color(0xFF6C63FF),
                                  trackHeight: 4,
                                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                                ),
                                child: Slider(
                                  min: 0.0,
                                  max: duration.inMilliseconds > 0 
                                    ? duration.inMilliseconds / 1000.0 
                                    : 100.0,
                                  value: (position.inMilliseconds / 1000.0).clamp(0.0, duration.inMilliseconds > 0 ? duration.inMilliseconds / 1000.0 : 100.0),
                                  onChanged: (val) {
                                    _localSeek(val);
                                  },
                                ),
                              )
                            : ClipRRect(
                                borderRadius: BorderRadius.circular(4),
                                child: LinearProgressIndicator(
                                  value: duration.inMilliseconds > 0 ? position.inMilliseconds / duration.inMilliseconds : 0.0,
                                  backgroundColor: Colors.white12,
                                  valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF00F2FE)),
                                  minHeight: 4,
                                ),
                              ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        formatDuration(duration),
                        style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                  // Button Bar
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      // Play/Pause & Volume controls (grouped together closer)
                      Expanded(
                        child: Row(
                          children: [
                            if (isMeHost) ...[
                              IconButton(
                                iconSize: 42,
                                color: Colors.white,
                                icon: Icon(isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled),
                                onPressed: isPlaying ? _localPause : _localPlay,
                              ),
                              IconButton(
                                iconSize: 32,
                                color: Colors.white,
                                icon: const Icon(Icons.skip_next),
                                onPressed: () {
                                  _socket.emit('skip-video', {'roomId': widget.roomId});
                                },
                              ),
                            ] else ...[
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                decoration: BoxDecoration(
                                  color: Colors.black45,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: Colors.white12),
                                ),
                                child: const Row(
                                  children: [
                                    Icon(Icons.visibility, size: 14, color: Color(0xFF00F2FE)),
                                    SizedBox(width: 6),
                                    Text(
                                      'Режим просмотра',
                                      style: TextStyle(fontSize: 11, color: Colors.white70, fontWeight: FontWeight.bold),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          const SizedBox(width: 8),
                          IconButton(
                            iconSize: 22,
                            icon: Icon(
                              volume == 0 
                                ? Icons.volume_off 
                                : Icons.volume_up,
                            ),
                            color: Colors.white70,
                            onPressed: () {
                              if (_mkPlayer!.state.volume > 0) {
                                _mkPlayer!.setVolume(0.0);
                              } else {
                                _mkPlayer!.setVolume(100.0);
                              }
                              setState(() {});
                            },
                          ),
                          Flexible(
                            child: SizedBox(
                              width: 100,
                              child: Slider(
                                value: volume.clamp(0.0, 1.0),
                                min: 0.0,
                                max: 1.0,
                                onChanged: (vol) {
                                  _mkPlayer!.setVolume(vol * 100);
                                  setState(() {});
                                },
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                      Row(
                        children: [
                          if (_currentVideoUrl.toLowerCase().contains('youtube.com') || _currentVideoUrl.toLowerCase().contains('youtu.be'))
                            DropdownButton<String>(
                              value: _preferredQuality,
                              dropdownColor: const Color(0xFF161426),
                              style: const TextStyle(fontSize: 12, color: Colors.white, fontWeight: FontWeight.bold),
                              underline: const SizedBox(),
                              icon: const Icon(Icons.settings, color: Colors.white70, size: 16),
                              items: const [
                                DropdownMenuItem(value: 'Auto', child: Text('Auto')),
                                DropdownMenuItem(value: '1080p', child: Text('1080p')),
                                DropdownMenuItem(value: '720p', child: Text('720p')),
                                DropdownMenuItem(value: '480p', child: Text('480p')),
                                DropdownMenuItem(value: '360p', child: Text('360p')),
                              ],
                              onChanged: (val) {
                                if (val != null && val != _preferredQuality) {
                                  setState(() {
                                    _preferredQuality = val;
                                  });
                                  _setupVideoPlayer(
                                    _currentVideoUrl, 
                                    _currentVideoName, 
                                    startPlaying: _mkPlayer?.state.playing ?? false,
                                    startSeconds: (_mkPlayer?.state.position.inMilliseconds ?? 0) / 1000.0,
                                  );
                                }
                              },
                            ),
                          const SizedBox(width: 8),
                          // Fullscreen toggle (Windows native fullscreen)
                          IconButton(
                            icon: const Icon(Icons.fullscreen),
                            color: Colors.white,
                            onPressed: () async {
                              if (Platform.isWindows) {
                                final isFullScreen = await windowManager.isFullScreen();
                                await windowManager.setFullScreen(!isFullScreen);
                              }
                            },
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Sidebar containing Room users, connection statuses and Link loading forms
  Widget _buildControlSidebar() {
    return Padding(
      padding: const EdgeInsets.all(12.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Tab bar at top of sidebar
          Row(
            children: [
              _buildTabItem(0, Icons.settings, _loc('controls')),
              _buildTabItem(1, Icons.chat, _loc('chat')),
              _buildTabItem(2, Icons.tune, _loc('settings')),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: _selectedTab == 0 
                ? _buildControlsTab() 
                : (_selectedTab == 1 ? _buildChatTab() : _buildSettingsTab()),
          ),
        ],
      ),
    );
  }

  Widget _buildTabItem(int index, IconData icon, String text) {
    final isSelected = _selectedTab == index;
    return Expanded(
      child: InkWell(
        onTap: () {
          setState(() {
            _selectedTab = index;
            if (index == 1) _unreadMessages = 0;
          });
        },
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: isSelected ? const Color(0xFF00F2FE) : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Center(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 14, color: isSelected ? const Color(0xFF00F2FE) : Colors.white54),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    text,
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: isSelected ? const Color(0xFF00F2FE) : Colors.white54,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (index == 1 && _unreadMessages > 0)
                  Container(
                    margin: const EdgeInsets.only(left: 4),
                    padding: const EdgeInsets.all(4),
                    decoration: const BoxDecoration(
                      color: Colors.redAccent,
                      shape: BoxShape.circle,
                    ),
                    child: Text(
                      _unreadMessages > 9 ? '9+' : _unreadMessages.toString(),
                      style: const TextStyle(color: Colors.white, fontSize: 8, fontWeight: FontWeight.bold),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildControlsTab() {
    // Check if the current user is host
    final isMeHost = _users.isNotEmpty && _users[0]['id'] == _socket.id;

    if (!isMeHost) {
      return SingleChildScrollView(
        child: Column(
          children: [
            const SizedBox(height: 20),
            _buildCard(
              child: Column(
                children: [
                  const Icon(Icons.lock, size: 42, color: Color(0xFF00F2FE)),
                  const SizedBox(height: 12),
                  const Text(
                    'Управление у Хоста 👑',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.white),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Только создатель комнаты может менять фильм, ставить на паузу или перематывать.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: Colors.white.withOpacity(0.6)),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            _loc('streamSettings'),
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.2,
              color: Color(0xFF00F2FE),
            ),
          ),
          const SizedBox(height: 10),
          // Remote Video Link Form
          _buildCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  _loc('streamWebLink'),
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                Text(
                  _locale == 'ru' 
                      ? 'Поддерживает VK, Rutube, прямые ссылки и плееры (api.collaps.to, alloha.tv)' 
                      : 'Supports VK, Rutube, direct video files and embeds (api.collaps.to, alloha.tv)',
                  style: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 10),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _urlInputController,
                  decoration: InputDecoration(
                    hintText: _loc('pasteVideoUrl'),
                    hintStyle: TextStyle(color: Colors.white.withOpacity(0.3), fontSize: 12),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    // Watch button (auto queues if already playing)
                    ElevatedButton(
                      onPressed: () {
                        if (_currentVideoUrl.isNotEmpty) {
                          _addToQueue(_urlInputController.text, 'Web Stream');
                        } else {
                          _changeVideo(_urlInputController.text, 'Web Stream');
                        }
                        _urlInputController.clear();
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF6C63FF),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      ),
                      child: Text(
                        _locale == 'ru' ? 'Смотреть' : 'Watch',
                        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          
          // Dubbing / Translator Selector
          if (_translators.isNotEmpty) ...[
            const SizedBox(height: 12),
            _buildCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.record_voice_over, size: 14, color: Color(0xFF6C63FF)),
                      const SizedBox(width: 6),
                      Text(
                        _locale == 'ru' ? 'Озвучка' : 'Dubbing',
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonHideUnderline(
                    child: DropdownButton<int>(
                      isExpanded: true,
                      dropdownColor: const Color(0xFF161426),
                      icon: const Icon(Icons.arrow_drop_down, color: Colors.white54),
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                      hint: Text(
                        _locale == 'ru' ? 'Выберите озвучку' : 'Select dubbing',
                        style: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 12),
                      ),
                      value: null,
                      items: _translators.map<DropdownMenuItem<int>>((t) {
                        final idx = t['index'] as int;
                        final name = t['name'].toString();
                        final isActive = t['isActive'] as bool? ?? false;
                        return DropdownMenuItem<int>(
                          value: idx,
                          child: Row(
                            children: [
                              if (isActive) ...[
                                const Icon(Icons.check, size: 12, color: Color(0xFF6C63FF)),
                                const SizedBox(width: 4),
                              ],
                              Text(name, style: TextStyle(
                                color: isActive ? const Color(0xFF6C63FF) : Colors.white,
                                fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
                              )),
                            ],
                          ),
                        );
                      }).toList(),
                      onChanged: (int? idx) {
                        if (idx != null) _switchDubbing(idx);
                      },
                    ),
                  ),
                ],
              ),
            ),
          ],

          const SizedBox(height: 12),

          // Playlist Queue Card
          if (_queue.isNotEmpty) ...[
            _buildCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        _locale == 'ru' ? 'Очередь воспроизведения' : 'Playback Queue',
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  ListView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: _queue.length,
                    itemBuilder: (context, index) {
                      final video = _queue[index];
                      return Container(
                        margin: const EdgeInsets.symmetric(vertical: 4),
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.03),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Row(
                          children: [
                            Text(
                              '${index + 1}.',
                              style: const TextStyle(color: Color(0xFF00F2FE), fontSize: 12, fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                (video['videoName'] ?? video['name'] ?? 'Web Stream').toString(),
                                style: const TextStyle(fontSize: 12, color: Colors.white),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (isMeHost)
                              IconButton(
                                icon: const Icon(Icons.delete_outline, size: 16, color: Colors.redAccent),
                                onPressed: () => _removeFromQueue(index),
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(),
                                tooltip: _locale == 'ru' ? 'Удалить из очереди' : 'Remove from queue',
                              ),
                          ],
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],

          // User Directory / Active audience
          Text(
            _loc('audience'),
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.2,
              color: Color(0xFF00F2FE),
            ),
          ),
          const SizedBox(height: 8),
          Container(
            height: 200, // Fixed height for scrolling in controls tab
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.02),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white.withOpacity(0.05)),
            ),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: _users.length,
              itemBuilder: (context, index) {
                final user = _users[index];
                final isMe = user['id'] == _socket.id;
                final isHost = index == 0; // First user is host

                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4.0, horizontal: 4),
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 11,
                        backgroundColor: isHost ? const Color(0xFF00F2FE) : const Color(0xFF6C63FF),
                        child: Text(
                          (user['username'] as String).substring(0, 1).toUpperCase(),
                          style: const TextStyle(fontSize: 9, color: Colors.black, fontWeight: FontWeight.bold),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${user['username']}${isMe ? " (You)" : ""}',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: isMe ? FontWeight.bold : FontWeight.normal,
                            color: isMe ? Colors.white : Colors.white.withOpacity(0.8),
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (isHost)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                          decoration: BoxDecoration(
                            color: Colors.amber.withOpacity(0.15),
                            border: Border.all(color: Colors.amber.withOpacity(0.5)),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            _loc('hostLabel'),
                            style: const TextStyle(fontSize: 7, color: Colors.amber, fontWeight: FontWeight.bold),
                          ),
                        ),
                      // Kick & Ban buttons (only visible to Host, and cannot kick/ban yourself)
                      if (isMeHost && !isMe) ...[
                        IconButton(
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          icon: const Icon(Icons.exit_to_app, color: Colors.orangeAccent, size: 16),
                          tooltip: _loc('kickTooltip'),
                          onPressed: () => _kickUser(user['id']),
                        ),
                        const SizedBox(width: 4),
                        IconButton(
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          icon: const Icon(Icons.block, color: Colors.redAccent, size: 16),
                          tooltip: _loc('banTooltip'),
                          onPressed: () => _banUser(user['id']),
                        ),
                      ],
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChatTab() {
    final primaryColor = Theme.of(context).primaryColor;

    return Column(
      children: [
        // Message log
        Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
            child: ListView.builder(
              controller: _chatScrollController,
              itemCount: _messages.length,
              itemBuilder: (context, index) {
                final msg = _messages[index];
                final isMe = msg['clientId'] == widget.clientId;
                final senderInitial = (msg['sender'] != null && msg['sender']!.isNotEmpty)
                    ? msg['sender']!.substring(0, 1).toUpperCase()
                    : '?';

                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    mainAxisAlignment: isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      if (!isMe)
                        Padding(
                          padding: const EdgeInsets.only(right: 8, bottom: 2),
                          child: CircleAvatar(
                            radius: 14,
                            backgroundColor: const Color(0xFF6C63FF).withOpacity(0.3),
                            child: Text(
                              senderInitial,
                              style: const TextStyle(fontSize: 10, color: Color(0xFF00F2FE), fontWeight: FontWeight.bold),
                            ),
                          ),
                        ),
                      Flexible(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                          constraints: const BoxConstraints(maxWidth: 260),
                          decoration: BoxDecoration(
                            gradient: isMe
                                ? LinearGradient(
                                    colors: [
                                      primaryColor,
                                      primaryColor.withOpacity(0.85),
                                    ],
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                  )
                                : null,
                            color: isMe ? null : Colors.white.withOpacity(0.08),
                            borderRadius: BorderRadius.only(
                              topLeft: const Radius.circular(16),
                              topRight: const Radius.circular(16),
                              bottomLeft: isMe ? const Radius.circular(16) : const Radius.circular(4),
                              bottomRight: isMe ? const Radius.circular(4) : const Radius.circular(16),
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.1),
                                blurRadius: 4,
                                offset: const Offset(0, 2),
                              )
                            ],
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (!isMe)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 2),
                                  child: Text(
                                    msg['sender'] ?? '',
                                    style: const TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                      color: Color(0xFF00F2FE),
                                    ),
                                  ),
                                ),
                              Text(
                                msg['text'] ?? '',
                                style: TextStyle(
                                  fontSize: _chatFontSize,
                                  color: Colors.white,
                                  height: 1.3,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Align(
                                alignment: Alignment.bottomRight,
                                child: Text(
                                  msg['time'] ?? '',
                                  style: TextStyle(
                                    fontSize: 9,
                                    color: Colors.white.withOpacity(0.5),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
        const SizedBox(height: 8),
        // Send message input bar
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.05),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: Colors.white.withOpacity(0.08)),
          ),
          child: Row(
            children: [
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _chatInputController,
                  focusNode: _chatFocusNode,
                  onSubmitted: (_) => _sendChatMessage(),
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  decoration: InputDecoration(
                    hintText: _loc('typeMessage'),
                    hintStyle: TextStyle(color: Colors.white.withOpacity(0.35), fontSize: 12),
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 8),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              InkWell(
                onTap: _sendChatMessage,
                borderRadius: BorderRadius.circular(20),
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      colors: [Color(0xFF00F2FE), Color(0xFF4FACFE)],
                    ),
                  ),
                  child: const Icon(Icons.send_rounded, size: 18, color: Colors.black),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSettingsTab() {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            _loc('settings').toUpperCase(),
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.2,
              color: Color(0xFF00F2FE),
            ),
          ),
          const SizedBox(height: 12),
          
          // Language selector
          _buildCard(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Flexible(
                  child: Text(
                    _loc('languageLabel'),
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                DropdownButton<String>(
                  value: _locale,
                  dropdownColor: const Color(0xFF161426),
                  style: const TextStyle(fontSize: 12, color: Colors.white),
                  items: const [
                    DropdownMenuItem(value: 'ru', child: Text('Русский')),
                    DropdownMenuItem(value: 'en', child: Text('English')),
                  ],
                  onChanged: (lang) {
                    if (lang != null) {
                      setState(() {
                        _locale = lang;
                      });
                      widget.onLocaleChange(lang);
                    }
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // Theme selector
          _buildCard(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Flexible(
                  child: Text(
                    _loc('themeLabel'),
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                DropdownButton<String>(
                  value: widget.themeName,
                  dropdownColor: const Color(0xFF161426),
                  style: const TextStyle(fontSize: 12, color: Colors.white),
                  items: [
                    DropdownMenuItem(value: 'Dark', child: Text(_loc('themeDark'))),
                    DropdownMenuItem(value: 'Neon Cyan', child: Text(_loc('themeCyan'))),
                    DropdownMenuItem(value: 'Sunset Gold', child: Text(_loc('themeGold'))),
                    DropdownMenuItem(value: 'Retro Purple', child: Text(_loc('themePurple'))),
                  ],
                  onChanged: (theme) {
                    if (theme != null) {
                      widget.onThemeChange(theme);
                    }
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // Chat font size slider
          _buildCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      _loc('chatFontSize'),
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                    Text(
                      '${_chatFontSize.toInt()} px',
                      style: const TextStyle(fontSize: 12, color: Color(0xFF00F2FE)),
                    ),
                  ],
                ),
                Slider(
                  min: 10.0,
                  max: 24.0,
                  divisions: 14,
                  value: _chatFontSize,
                  activeColor: const Color(0xFF6C63FF),
                  inactiveColor: Colors.white12,
                  onChanged: (val) {
                    setState(() {
                      _chatFontSize = val;
                    });
                    widget.onChatFontSizeChange(val);
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          // View App Logs card
          _buildCard(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Row(
                  children: [
                    Icon(Icons.bug_report, size: 16, color: Color(0xFF00F2FE)),
                    SizedBox(width: 8),
                    Text(
                      'Логи приложения / Logs',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                ElevatedButton(
                  onPressed: _showLogsDialog,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF6C63FF),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  ),
                  child: const Text('Показать', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          // Check for Updates card
          _buildCard(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Row(
                  children: [
                    Icon(Icons.system_update, size: 16, color: Color(0xFF00F2FE)),
                    SizedBox(width: 8),
                    Text(
                      'Автообновление (v1.1.4)',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                ElevatedButton(
                  onPressed: () {
                    final targetUrl = widget.serverUrl.isNotEmpty ? widget.serverUrl : 'https://ravestreamerserver.onrender.com';
                    _fetchVersionFromServer(targetUrl, verbose: true);
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00F2FE).withOpacity(0.2),
                    foregroundColor: const Color(0xFF00F2FE),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                      side: const BorderSide(color: Color(0xFF00F2FE)),
                    ),
                  ),
                  child: Text(
                    _locale == 'ru' ? 'Проверить' : 'Check',
                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _fetchVersionFromServer(String dummy, {bool verbose = false}) async {
    try {
      final gistRawUrl = 'https://gist.githubusercontent.com/stepa1235/0811a2ec6e74b06965de32f61643da5b/raw/ravestreamer.json?t=${DateTime.now().millisecondsSinceEpoch}';
      final res = await http.get(
        Uri.parse(gistRawUrl),
        headers: {'Cache-Control': 'no-cache'},
      ).timeout(const Duration(seconds: 6));

      if (res.statusCode == 200) {
        final jsonData = jsonDecode(res.body) as Map<String, dynamic>;
        _checkForUpdates(jsonData, verbose: verbose);
        return;
      }
    } catch (e) {
      debugPrint('Could not fetch version from Gist: $e');
    }
    if (verbose && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_locale == 'ru' ? 'Не удалось проверить обновления' : 'Could not check for updates'),
        ),
      );
    }
  }

  bool _isNewerVersion(String latest, String current) {
    try {
      List<int> parse(String v) => v.split('.').map((e) => int.tryParse(e.replaceAll(RegExp(r'\D'), '')) ?? 0).toList();
      final l = parse(latest);
      final c = parse(current);
      final maxLen = l.length > c.length ? l.length : c.length;
      for (int i = 0; i < maxLen; i++) {
        final lNum = i < l.length ? l[i] : 0;
        final cNum = i < c.length ? c[i] : 0;
        if (lNum > cNum) return true;
        if (lNum < cNum) return false;
      }
    } catch (_) {}
    return false;
  }

  void _checkForUpdates(Map<String, dynamic> jsonData, {bool verbose = false}) {
    if (!jsonData.containsKey('latest_version')) return;
    final latestVersion = jsonData['latest_version'] as String;
    const String currentVersion = '1.1.4';

    if (_isNewerVersion(latestVersion, currentVersion)) {
      String downloadUrl = '';
      if (Platform.isAndroid) {
        downloadUrl = jsonData['android_url'] as String? ?? '';
      } else if (Platform.isWindows) {
        downloadUrl = jsonData['windows_url'] as String? ?? '';
      }

      if (downloadUrl.isEmpty) return;

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _showUpdateDialog(latestVersion, downloadUrl);
        }
      });
    } else if (verbose && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _locale == 'ru'
                ? 'У вас установлена последняя версия v$currentVersion! ✨'
                : 'You are using the latest version v$currentVersion! ✨',
          ),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  void _showUpdateDialog(String version, String downloadUrl) {
    final activeTheme = _themes[widget.themeName] ?? _themes['Dark']!;
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
            _locale == 'ru' ? 'Доступно обновление v$version! 🚀' : 'Update Available v$version! 🚀',
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _locale == 'ru'
                    ? 'Вышла новая версия RaveStreamer v$version.\nНажмите «Авто-установка» для скачивания внутри приложения!'
                    : 'A new version of RaveStreamer v$version is available.\nTap "Auto-Install" for direct in-app download!',
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 12),
              SelectableText(
                downloadUrl,
                style: const TextStyle(color: Color(0xFF00F2FE), fontSize: 11, decoration: TextDecoration.underline),
              ),
            ],
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
                _downloadAndInstallUpdate(downloadUrl, version);
              },
              label: Text(
                _locale == 'ru' ? 'Авто-установка v$version' : 'Auto-Install v$version',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _downloadAndInstallUpdate(String downloadUrl, String version) async {
    double progress = 0.0;
    StateSetter? dialogSetState;
    bool isDownloading = true;
    String statusText = _locale == 'ru' ? 'Подключение к серверу...' : 'Connecting to server...';

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
                  const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF00F2FE)))
                else
                  const Icon(Icons.check_circle, color: Colors.green),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _locale == 'ru' ? 'Автообновление v$version' : 'Auto-Updating v$version',
                    style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(statusText, style: const TextStyle(color: Colors.white70, fontSize: 13)),
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
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    '${(progress * 100).toStringAsFixed(1)}%',
                    style: const TextStyle(color: Color(0xFF00F2FE), fontSize: 13, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );

    try {
      final req = http.Request('GET', Uri.parse(downloadUrl));
      final res = await http.Client().send(req);
      final total = res.contentLength ?? 0;
      int received = 0;

      final tempDir = Directory.systemTemp;
      final apkPath = '${tempDir.path}/app-release.apk';
      final apkFile = File(apkPath);
      if (await apkFile.exists()) await apkFile.delete();

      final sink = apkFile.openWrite();

      await res.stream.forEach((chunk) {
        received += chunk.length;
        sink.add(chunk);
        if (total > 0 && dialogSetState != null) {
          dialogSetState!(() {
            progress = received / total;
            final mbReceived = (received / (1024 * 1024)).toStringAsFixed(1);
            final mbTotal = (total / (1024 * 1024)).toStringAsFixed(1);
            statusText = _locale == 'ru'
                ? 'Загрузка: $mbReceived MB / $mbTotal MB'
                : 'Downloading: $mbReceived MB / $mbTotal MB';
          });
        }
      });

      await sink.close();

      if (dialogSetState != null) {
        dialogSetState!(() {
          isDownloading = false;
          statusText = _locale == 'ru' ? 'Скачано! Запуск установки...' : 'Downloaded! Launching installer...';
        });
      }

      await Future.delayed(const Duration(milliseconds: 500));
      if (mounted) Navigator.of(context).pop();

      // Launch installer
      final result = await OpenFilex.open(apkPath, type: "application/vnd.android.package-archive");
      debugPrint('OpenFilex result: ${result.type} ${result.message}');
      if (result.type != ResultType.done) {
        await launchUrl(Uri.parse(downloadUrl), mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      debugPrint('Auto-download error: $e');
      if (mounted) Navigator.of(context).pop();
      try {
        await launchUrl(Uri.parse(downloadUrl), mode: LaunchMode.externalApplication);
      } catch (_) {}
    }
  }

  void _showLogsDialog() {
    showDialog(
      context: context,
      builder: (context) {
        final logsText = AppLogger.logs.isEmpty ? 'Логов пока нет' : AppLogger.logs.join('\n');
        return AlertDialog(
          backgroundColor: const Color(0xFF161426),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Логи приложения', style: TextStyle(fontSize: 15, color: Colors.white, fontWeight: FontWeight.bold)),
              IconButton(
                icon: const Icon(Icons.copy, size: 18, color: Color(0xFF00F2FE)),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: logsText));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Логи скопированы в буфер!')),
                  );
                },
                tooltip: 'Скопировать логи',
              ),
            ],
          ),
          content: SizedBox(
            width: double.maxFinite,
            height: 350,
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.white.withOpacity(0.1)),
              ),
              child: SingleChildScrollView(
                child: SelectableText(
                  logsText,
                  style: const TextStyle(fontSize: 10, fontFamily: 'monospace', color: Colors.greenAccent),
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Закрыть', style: TextStyle(color: Colors.white54)),
            ),
          ],
        );
      },
    );
  }

  // Collapsed Sidebar for Mobile Devices
  Widget _buildControlSidebarCollapsed() {
    return Container(
      color: const Color(0xFF100E1C),
      padding: const EdgeInsets.all(16.0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _urlInputController,
                  decoration: InputDecoration(
                    hintText: _loc('pasteVideoUrl'),
                    hintStyle: TextStyle(color: Colors.white.withOpacity(0.3), fontSize: 13),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              // Use flat TextButton instead of solid elevated button
              TextButton(
                onPressed: () {
                  _changeVideo(_urlInputController.text, 'Web Stream');
                  _urlInputController.clear();
                },
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFF00F2FE),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                ),
                child: Text(_loc('load'), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  '${_loc('video')}$_currentVideoName',
                  style: TextStyle(fontSize: 12, color: Colors.white.withOpacity(0.6)),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              TextButton.icon(
                onPressed: _pickLocalFile,
                icon: const Icon(Icons.folder_open, size: 14),
                label: Text(_loc('chooseVideoFile'), style: const TextStyle(fontSize: 11)),
              ),
              TextButton.icon(
                onPressed: _showChatDialog,
                icon: const Icon(Icons.chat_bubble_outline, size: 14),
                label: Text(_loc('chat'), style: const TextStyle(fontSize: 11)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCard({required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.03),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withOpacity(0.06)),
      ),
      child: child,
    );
  }

  // Users Dialog for mobile
  void _showUsersDialog() {
    showDialog(
      context: context,
      builder: (context) {
        final isMeHost = _users.isNotEmpty && _users[0]['id'] == _socket.id;
        
        return AlertDialog(
          title: Text(_loc('activeUsers')),
          backgroundColor: const Color(0xFF161426),
          content: SizedBox(
            width: 250,
            height: 300,
            child: ListView.builder(
              itemCount: _users.length,
              itemBuilder: (context, index) {
                final user = _users[index];
                final isMe = user['id'] == _socket.id;
                final isHost = index == 0;
                
                return ListTile(
                  leading: CircleAvatar(
                    backgroundColor: isHost ? const Color(0xFF00F2FE) : const Color(0xFF6C63FF),
                    child: Text(
                      (user['username'] as String).substring(0, 1).toUpperCase(),
                      style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold),
                    ),
                  ),
                  title: Text(
                    '${user['username']}${isMe ? " (You)" : ""}',
                    style: TextStyle(fontWeight: isMe ? FontWeight.bold : FontWeight.normal),
                  ),
                  trailing: isHost 
                    ? Chip(label: Text(_loc('hostLabel'), style: const TextStyle(fontSize: 10))) 
                    : (isMeHost && !isMe 
                        ? Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.exit_to_app, color: Colors.orangeAccent),
                                tooltip: _loc('kickTooltip'),
                                onPressed: () {
                                  _kickUser(user['id']);
                                  Navigator.pop(context); // Close dialog
                                },
                              ),
                              IconButton(
                                icon: const Icon(Icons.block, color: Colors.redAccent),
                                tooltip: _loc('banTooltip'),
                                onPressed: () {
                                  _banUser(user['id']);
                                  Navigator.pop(context); // Close dialog
                                },
                              ),
                            ],
                          ) 
                        : null),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(_loc('close')),
            ),
          ],
        );
      },
    );
  }

  // Mobile Chat Dialog
  void _showChatDialog() {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(_loc('chatRoom')),
          backgroundColor: const Color(0xFF161426),
          content: SizedBox(
            width: 350,
            height: 450,
            child: _buildChatTab(),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(_loc('close')),
            ),
          ],
        );
      },
    );
  }
}

class MultipartRequestWithProgress extends http.MultipartRequest {
  final void Function(int bytesTransferred, int totalBytes) onProgress;

  MultipartRequestWithProgress(
    String method,
    Uri url, {
    required this.onProgress,
  }) : super(method, url);

  @override
  http.ByteStream finalize() {
    final byteStream = super.finalize();
    final total = contentLength;
    int bytes = 0;

    final transformer = StreamTransformer<List<int>, List<int>>.fromHandlers(
      handleData: (data, sink) {
        bytes += data.length;
        onProgress(bytes, total);
        sink.add(data);
      },
    );

    return http.ByteStream(byteStream.transform(transformer));
  }
}

class AppLogger {
  static final List<String> logs = [];

  static void log(String msg) {
    final timestamp = DateTime.now().toIso8601String().substring(11, 19);
    final line = '[$timestamp] $msg';
    debugPrint(line);
    logs.add(line);
    if (logs.length > 500) logs.removeAt(0);

    try {
      final logPath = Platform.isWindows
          ? 'C:\\RaveStreamer\\client_debug.log'
          : '${Directory.systemTemp.path}/ravestreamer_android.log';
      final file = File(logPath);
      file.writeAsStringSync('$line\n', mode: FileMode.append);
    } catch (_) {}
  }
}

class WebviewPlayer {
  late final WebViewController controller;
  final state = WebviewPlayerState();
  final stream = WebviewPlayerStream();
  bool _isInitialized = false;
  bool _isPageReady = false;
  Map<String, dynamic>? _pendingLoadCmd;
  HttpServer? _localServer;
  int _localPort = 0;

  int get localPort => _localPort;
  bool get isInitialized => _isInitialized;

  void _logToFile(String msg) {
    AppLogger.log(msg);
  }

  Future<void> initialize() async {
    try {
      _localServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _localPort = _localServer!.port;
      _logToFile('Local server started on port $_localPort');
      
      _localServer!.listen((HttpRequest request) async {
        final path = request.uri.path;
        final clientIp = request.connectionInfo?.remoteAddress.address ?? 'unknown';
        
        request.response.headers.add('Access-Control-Allow-Origin', '*');
        request.response.headers.add('Access-Control-Allow-Headers', '*');
        request.response.headers.add('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
        
        if (request.method == 'OPTIONS') {
          request.response.statusCode = HttpStatus.ok;
          request.response.close();
          return;
        }

        if (path == '/file') {
          final filePath = request.uri.queryParameters['path'];
          if (filePath != null && File(filePath).existsSync()) {
            try {
              final file = File(filePath);
              final len = await file.length();
              request.response.headers.contentLength = len;
              request.response.headers.contentType = ContentType.parse('video/mp4');
              await file.openRead().pipe(request.response);
            } catch (e) {
              request.response.statusCode = HttpStatus.internalServerError;
              request.response.close();
            }
          } else {
            request.response.statusCode = HttpStatus.notFound;
            request.response.close();
          }
        } else if (path == '/proxy') {
          final urlParam = request.uri.queryParameters['url'];
          final cookiesParam = request.uri.queryParameters['cookies'];
          final refererParam = request.uri.queryParameters['referer'];
          
          if (urlParam == null) {
            _logToFile('Proxy request error: Missing url parameter');
            request.response.statusCode = HttpStatus.badRequest;
            request.response.write('Missing url');
            request.response.close();
            return;
          }
          
          try {
            final client = HttpClient();
            var targetUri = Uri.parse(urlParam);
            HttpClientRequest? targetRequest;
            HttpClientResponse? targetResponse;
            
            for (var redirectCount = 0; redirectCount < 10; redirectCount++) {
              targetRequest = await client.getUrl(targetUri);
              targetRequest.followRedirects = false;
              
              final rangeHeader = request.headers.value('range');
              if (rangeHeader != null) {
                targetRequest.headers.set('Range', rangeHeader);
              }
              
              final userAgent = request.headers.value('user-agent') ?? 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
              targetRequest.headers.set('User-Agent', userAgent);
              targetRequest.headers.set('Accept', '*/*');
              
              if (cookiesParam != null && cookiesParam.isNotEmpty) {
                targetRequest.headers.set('Cookie', cookiesParam);
              }
              if (refererParam != null && refererParam.isNotEmpty) {
                try {
                  final refUri = Uri.parse(refererParam);
                  targetRequest.headers.set('Referer', '${refUri.scheme}://${refUri.host}/');
                  targetRequest.headers.set('Origin', '${refUri.scheme}://${refUri.host}');
                } catch (_) {}
              }
              
              targetResponse = await targetRequest.close();
              
              if (targetResponse.statusCode >= 300 && targetResponse.statusCode < 400) {
                final loc = targetResponse.headers.value('location');
                if (loc != null) {
                  targetUri = targetUri.resolve(loc);
                  continue;
                }
              }
              break;
            }
            
            request.response.statusCode = targetResponse!.statusCode;
            targetResponse.headers.forEach((name, values) {
              final lowerName = name.toLowerCase();
              if (lowerName == 'transfer-encoding' || lowerName == 'content-encoding' || lowerName == 'access-control-allow-origin') return;
              if (lowerName == 'content-length') {
                try { request.response.contentLength = int.parse(values.first); } catch (_) {}
                return;
              }
              if (lowerName == 'location') return;
              for (var value in values) { request.response.headers.add(name, value); }
            });
            
            final contentType = targetResponse.headers.value('content-type') ?? '';
            final isPlaylist = contentType.contains('mpegurl') || contentType.contains('x-mpegurl') || urlParam.contains('.m3u8');
            
            if (isPlaylist) {
              final bytes = await targetResponse.fold<List<int>>([], (p, e) => p..addAll(e));
              final text = utf8.decode(bytes);
              final rewritten = text.split('\n').map((line) {
                final trimmed = line.trim();
                if (trimmed.isEmpty || trimmed.startsWith('#')) return line;
                var absUrl = trimmed;
                try { absUrl = Uri.parse(targetUri.toString()).resolve(trimmed).toString(); } catch (_) {}
                return 'http://127.0.0.1:$_localPort/proxy?url=${Uri.encodeComponent(absUrl)}&cookies=${Uri.encodeComponent(cookiesParam ?? '')}&referer=${Uri.encodeComponent(refererParam ?? '')}';
              }).join('\n');
              request.response.headers.contentType = ContentType('application', 'vnd.apple.mpegurl');
              request.response.write(rewritten);
              request.response.close();
            } else {
              await targetResponse.pipe(request.response);
            }
          } catch (e) {
            _logToFile('Local proxy server error: $e');
            request.response.statusCode = HttpStatus.internalServerError;
            request.response.write('Local proxy error: $e');
            request.response.close();
          }
        } else {
          _logToFile('Serving HTML player template');
          request.response.headers.contentType = ContentType.html;
          request.response.write(_htmlPlayerCode);
          request.response.close();
        }
      });
      debugPrint('[webview] Local server running on port $_localPort');
    } catch (e) {
      debugPrint('[webview] Failed to start local server: $e');
    }

    controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0x00000000))
      ..setUserAgent("Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36")
      ..addJavaScriptChannel(
        'FlutterChannel',
        onMessageReceived: (JavaScriptMessage message) {
          final event = message.message;
          try {
            final data = jsonDecode(event) as Map<String, dynamic>;
            final type = data['type'] as String?;
            if (type == 'ready') {
              _isPageReady = true;
              _logToFile('WebView HTML player is READY');
              if (_pendingLoadCmd != null) {
                final jsonStr = jsonEncode(_pendingLoadCmd).replaceAll("'", "\\'");
                _pendingLoadCmd = null;
                controller.runJavaScript("window.postMessage('$jsonStr', '*')");
              }
            } else if (type == 'state') {
              state.playing = data['playing'] as bool? ?? false;
              state.position = Duration(milliseconds: data['position'] as int? ?? 0);
              state.duration = Duration(milliseconds: data['duration'] as int? ?? 0);
              state.volume = data['volume'] as int? ?? 100;

              stream._playingController.add(state.playing);
              stream._positionController.add(state.position);
              stream._durationController.add(state.duration);
            } else if (type == 'ended') {
              stream._completedController.add(true);
            } else if (type == 'log') {
              _logToFile('[JS Console] ${data['message']}');
            } else if (type == 'error') {
              stream._errorController.add(data['message']);
              _logToFile('[JS Error] ${data['message']}');
            }
          } catch (e) {
            debugPrint('[webview] Event parsing error: $e');
          }
        },
      );

    if (controller.platform is AndroidWebViewController) {
      (controller.platform as AndroidWebViewController).setMediaPlaybackRequiresUserGesture(false);
    }

    _isInitialized = true;
    if (_localPort > 0) {
      await controller.loadRequest(Uri.parse('http://127.0.0.1:$_localPort/'));
    } else {
      await controller.loadHtmlString(_htmlPlayerCode);
    }
  }

  bool _isEmbedActive = false;

  Future<void> open(Media media, {bool play = false}) async {
    if (!_isInitialized) return;
    final headers = <String, String>{};
    if (media.httpHeaders != null) media.httpHeaders!.forEach((k, v) => headers[k] = v.toString());

    var playUrl = media.resource;
    _logToFile('Opening media resource: $playUrl');

    final isProxyOrStream = playUrl.contains('/proxy/') || 
                            playUrl.contains('.m3u8') || 
                            playUrl.contains('.mp4') ||
                            playUrl.contains('.mkv') ||
                            playUrl.contains('.webm');

    final isEmbed = !isProxyOrStream && (
      playUrl.contains('/iframe') || 
      playUrl.contains('video_ext.php') || 
      playUrl.contains('rutube.ru/play') || 
      playUrl.contains('youtube.com/embed') ||
      playUrl.contains('vk.com/video_ext.php') ||
      playUrl.contains('vkvideo.ru')
    );

    if (isEmbed) {
      _isEmbedActive = true;
      _logToFile('Detected embed / iframe URL. Loading directly in WebViewController: $playUrl');
      await controller.loadRequest(Uri.parse(playUrl));
    } else {
      final isHttp = playUrl.startsWith('http') || playUrl.startsWith('https');
      if (!isHttp) {
        playUrl = 'http://127.0.0.1:$_localPort/file?path=${Uri.encodeComponent(playUrl)}';
      }

      final cmd = {'action': 'load', 'url': playUrl, 'headers': headers, 'play': play};

      if (_isEmbedActive || !_isPageReady) {
        _isEmbedActive = false;
        _isPageReady = false;
        _pendingLoadCmd = cmd;
        _logToFile('Reloading local HTML5 player page after embed/iframe URL...');
        if (_localPort > 0) {
          await controller.loadRequest(Uri.parse('http://127.0.0.1:$_localPort/'));
        } else {
          await controller.loadHtmlString(_htmlPlayerCode);
        }
      } else {
        final jsonStr = jsonEncode(cmd).replaceAll("'", "\\'");
        await controller.runJavaScript("window.postMessage('$jsonStr', '*')");
      }
    }
  }

  Future<void> play() async {
    if (!_isInitialized) return;
    await controller.runJavaScript("window.postMessage('{\"action\":\"play\"}', '*')");
  }

  Future<void> pause() async {
    if (!_isInitialized) return;
    await controller.runJavaScript("window.postMessage('{\"action\":\"pause\"}', '*')");
  }

  Future<void> seek(Duration duration) async {
    if (!_isInitialized) return;
    final timeVal = duration.inMilliseconds / 1000.0;
    await controller.runJavaScript("window.postMessage('{\"action\":\"seek\",\"time\":$timeVal}', '*')");
  }

  Future<void> setVolume(double vol) async {
    if (!_isInitialized) return;
    final volVal = vol.toInt();
    await controller.runJavaScript("window.postMessage('{\"action\":\"volume\",\"volume\":$volVal}', '*')");
  }

  Future<void> dispose() async {
    _localServer?.close(force: true);
  }
}

class WebviewPlayerState {
  bool playing = false;
  Duration position = Duration.zero;
  Duration duration = Duration.zero;
  int volume = 100;
}

class WebviewPlayerStream {
  final _completedController = StreamController<bool>.broadcast();
  final _errorController = StreamController<dynamic>.broadcast();
  final _playingController = StreamController<bool>.broadcast();
  final _positionController = StreamController<Duration>.broadcast();
  final _durationController = StreamController<Duration>.broadcast();

  Stream<bool> get completed => _completedController.stream;
  Stream<dynamic> get error => _errorController.stream;
  Stream<bool> get playing => _playingController.stream;
  Stream<Duration> get position => _positionController.stream;
  Stream<Duration> get duration => _durationController.stream;
}

class Media {
  final String resource;
  final Map<String, String>? httpHeaders;
  Media(this.resource, {this.httpHeaders});
}

const String _htmlPlayerCode = r'''
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
  <style>
    body, html { margin: 0; padding: 0; width: 100%; height: 100%; background: black; overflow: hidden; }
    video { width: 100%; height: 100%; object-fit: contain; }
  </style>
  <script src="https://cdn.jsdelivr.net/npm/hls.js@1" onerror="loadFallbackHls(this)"></script>
  <script>
    function loadFallbackHls(script) {
      console.log('JSDelivr CDN failed, loading fallback cdnjs...');
      var s = document.createElement('script');
      s.src = "https://cdnjs.cloudflare.com/ajax/libs/hls.js/1.5.8/hls.min.js";
      s.onerror = function() {
        console.log('cdnjs failed, loading fallback unpkg...');
        var s2 = document.createElement('script');
        s2.src = "https://unpkg.com/hls.js@1";
        document.head.appendChild(s2);
      };
      document.head.appendChild(s);
    }
  </script>
</head>
<body>
  <video id="player" autoplay playsinline webkit-playsinline></video>
  <script>
    function postMessageToFlutter(data) {
      const str = typeof data === 'string' ? data : JSON.stringify(data);
      try {
        if (window.FlutterChannel) {
          window.FlutterChannel.postMessage(str);
        } else if (window.chrome && window.chrome.webview) {
          window.chrome.webview.postMessage(str);
        }
      } catch (e) {}
    }

    window.onerror = function(msg, url, line) {
      postMessageToFlutter({ type: 'error', message: msg + ' (' + url + ':' + line + ')' });
    };
    console.log = function(...args) {
      postMessageToFlutter({ type: 'log', message: args.join(' ') });
    };
    console.error = function(...args) {
      postMessageToFlutter({ type: 'error', message: args.join(' ') });
    };

    const video = document.getElementById('player');

    function safePlay() {
      var promise = video.play();
      if (promise !== undefined) {
        promise.catch(function(error) {
          console.log('Autoplay error: ' + error.message + '. Muting and retrying...');
          video.muted = true;
          video.play().catch(function(err2) {
            console.error('Final play failure: ' + err2.message);
          });
        });
      }
    }
    
    function sendState() {
      postMessageToFlutter({
        type: 'state',
        playing: !video.paused,
        position: Math.floor(video.currentTime * 1000),
        duration: Math.floor(video.duration * 1000) || 0,
        volume: Math.floor(video.volume * 100)
      });
    }

    video.addEventListener('play', sendState);
    video.addEventListener('pause', sendState);
    video.addEventListener('timeupdate', sendState);
    video.addEventListener('durationchange', sendState);
    video.addEventListener('ended', () => postMessageToFlutter({ type: 'ended' }));
    video.addEventListener('error', (e) => {
      var err = video.error;
      if (err) {
        console.error('HTML5 Video Error code ' + err.code + ': ' + err.message);
      }
    });

    window.addEventListener('message', function(e) {
      try {
        let cmd = typeof e.data === 'string' ? JSON.parse(e.data) : e.data;
        if (cmd.action === 'load') {
          video.pause();
          if (window.hls) { hls.destroy(); hls = null; }
          const isM3U8 = cmd.url.includes('.m3u8') || cmd.url.includes('/proxy/hls');
          const hasHls = typeof Hls !== 'undefined';
          if (hasHls && Hls.isSupported() && isM3U8) {
            console.log('Initializing HLS.js for URL: ' + cmd.url);
            window.hls = new Hls({
              enableWorker: true,
              lowLatencyMode: true,
              backBufferLength: 90
            });
            hls.loadSource(cmd.url);
            hls.attachMedia(video);
            hls.on(Hls.Events.MANIFEST_PARSED, () => {
              console.log('HLS Manifest parsed successfully!');
              if (cmd.play) safePlay();
            });
            hls.on(Hls.Events.ERROR, function(event, data) {
              console.log('HLS Event Error: ' + data.type + ' / ' + data.details + ' / fatal: ' + data.fatal);
              if (data.fatal) {
                switch (data.type) {
                  case Hls.ErrorTypes.NETWORK_ERROR:
                    console.log('Fatal network error, attempting HLS reload...');
                    hls.startLoad();
                    break;
                  case Hls.ErrorTypes.MEDIA_ERROR:
                    console.log('Fatal media error, attempting media recovery...');
                    hls.recoverMediaError();
                    break;
                  default:
                    console.log('Unrecoverable HLS error, falling back to direct video.src');
                    hls.destroy();
                    video.src = cmd.url;
                    if (cmd.play) safePlay();
                    break;
                }
              }
            });
          } else {
            console.log('Loading direct video source: ' + cmd.url);
            video.src = cmd.url;
            if (cmd.play) safePlay();
          }
        } else if (cmd.action === 'play') {
          safePlay();
        } else if (cmd.action === 'pause') {
          video.pause();
        } else if (cmd.action === 'seek') {
          video.currentTime = cmd.time;
        } else if (cmd.action === 'volume') {
          video.volume = cmd.volume / 100;
        }
      } catch (err) {
        postMessageToFlutter({
          type: 'error',
          message: err.toString()
        });
      }
    });
    
    postMessageToFlutter({ type: 'ready' });
  </script>
</body>
</html>
''';

