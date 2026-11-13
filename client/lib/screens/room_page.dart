import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' show ImageFilter;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;
import 'package:http/http.dart' as http;
import 'package:window_manager/window_manager.dart';
import 'package:webview_windows/webview_windows.dart';
import 'package:local_notifier/local_notifier.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart' hide Video;
import 'package:url_launcher/url_launcher.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:pasteboard/pasteboard.dart';
import '../webrtc_manager.dart';
import '../core/constants/localization.dart';
import '../core/services/settings_service.dart';
import '../core/services/update_service.dart';
import '../player/webview_player.dart';
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
  late io.Socket _socket;
  WebviewPlayer? _mkPlayer;
  bool _playerReady = false; // becomes true once player is initialized

  // App states
  bool _isConnected = false;
  bool _hasJoinedRoom = false;
  List<dynamic> _users = [];
  String _currentVideoUrl = '';
  String _currentVideoName = 'No Video Loaded';
  bool _isIncomingUpdate = false;
  bool _isDisposed = false;
  bool _isSidebarVisible = true;

  // WebRTC & Live Frame
  WebRTCManager? _webrtcManager;
  HttpServer? _localHttpServer;
  bool _isLiveStreaming = false;
  List<dynamic> _queue = [];
  String _preferredQuality = 'Auto';
  List<dynamic> _translators = [];
  String _currentPageUrl = ''; // original lordfilm/site URL (for translator switching)
  String? _hostUsername;
  String? _hostToken;

  // Real-time reactive users notifier for dialog & participants
  final ValueNotifier<List<dynamic>> _usersNotifier = ValueNotifier<List<dynamic>>([]);
  bool _showSystemMessages = true;
  bool _showChatTimestamps = true;
  bool _chatSounds = true;
  bool _autoScrollChat = true;
  double _syncToleranceSec = 2.0;
  bool _compactChat = false;
  bool _isPipMode = false;
  Rect? _beforePipBounds;
  bool _isDraggingOver = false;

  bool get _isHost {
    if (_isLocalStreamHost) return true;
    if (_socket.id != null) {
      for (final u in _users) {
        if (u['id'] == _socket.id && u['isHost'] == true) return true;
      }
    }
    if (_hostToken != null && _hostToken!.isNotEmpty) return true;
    return false;
  }

  void _emitJoinRoom({String? passwordOverride}) {
    final tok = _hostToken ?? globalHostTokens[widget.roomId];
    _socket.emit('join-room', {
      'roomId': widget.roomId,
      'username': widget.username,
      'password': passwordOverride ?? widget.password,
      'clientId': widget.clientId,
      'hostToken': tok,
    });
  }

  // Tabs, Chat & Localization States
  int _selectedTab = 0; // 0 = Controls, 1 = Chat, 2 = Settings
  final List<Map<String, dynamic>> _messages = [];
  Map<String, dynamic>? _replyingTo;
  bool _isUploadingImage = false;
  bool _showScrollToBottom = false;
  late double _chatFontSize; // Default chat font size
  late String _locale;

  final _urlInputController = TextEditingController();
  final _localPathController = TextEditingController();
  final _chatInputController = TextEditingController();
  final _chatScrollController = ScrollController();
  final _chatFocusNode = FocusNode(); // FocusNode to keep keyboard open

  Timer? _syncTimer;
  bool _showControls = true;
  Timer? _controlsTimer;

  String _loc(String key) {
    return localizedValues[_locale]?[key] ?? key;
  }

  @override
  void initState() {
    super.initState();
    _locale = widget.locale;
    _chatFontSize = widget.chatFontSize;
    _hostToken = globalHostTokens[widget.roomId];
    _usersNotifier.value = List.from(_users);

    _chatScrollController.addListener(() {
      if (!_chatScrollController.hasClients) return;
      final max = _chatScrollController.position.maxScrollExtent;
      final current = _chatScrollController.position.pixels;
      final show = (max - current) > 120;
      if (show != _showScrollToBottom && mounted) {
        setState(() {
          _showScrollToBottom = show;
        });
      }
    });

    // Load stream and UI settings
    loadSettings().then((data) {
      if (mounted) {
        setState(() {
          if (data.containsKey('preferredQuality')) _preferredQuality = data['preferredQuality'];
          if (data.containsKey('showSystemMessages')) _showSystemMessages = data['showSystemMessages'] == true;
          if (data.containsKey('showChatTimestamps')) _showChatTimestamps = data['showChatTimestamps'] == true;
          if (data.containsKey('chatSounds')) _chatSounds = data['chatSounds'] == true;
          if (data.containsKey('autoScrollChat')) _autoScrollChat = data['autoScrollChat'] == true;
          if (data.containsKey('syncToleranceSec')) _syncToleranceSec = (data['syncToleranceSec'] as num).toDouble();
          if (data.containsKey('compactChat')) _compactChat = data['compactChat'] == true;
        });
      }
    });

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
      if (_isHost) _socket.emit('skip-video', {'roomId': widget.roomId});
    });
    player.stream.error.listen((err) {
      debugPrint('[webview] ERROR: $err');
      if (mounted) {
        /* SnackBar disabled */
      }
    });
    player.stream.playing.listen((_) { if (mounted) setState(() {}); });
    player.stream.position.listen((_) { if (mounted) setState(() {}); });
    player.stream.duration.listen((_) { if (mounted) setState(() {}); });
    player.stream.tracks.listen((_) { if (mounted) setState(() {}); });
    _initSocket();
    _syncTimer = Timer.periodic(const Duration(seconds: 3), (timer) {
      _sendPeriodicSync();
    });

    // Connection timeout check (15 seconds for server wakeup)
    Timer(const Duration(seconds: 15), () {
      if (mounted && !_hasJoinedRoom) {
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF2A2D3E),
            title: Text(
              _locale == 'ru' ? 'Подключение задерживается' : 'Connection Delay',
              style: const TextStyle(color: Colors.orangeAccent, fontWeight: FontWeight.bold),
            ),
            content: Text(
              _locale == 'ru'
                ? 'Сервер подключается дольше обычного (пробуждение сервера)... Вы можете подождать или продолжить.'
                : 'Server is taking longer to connect (server waking up)... You can wait or continue anyway.',
              style: const TextStyle(color: Colors.white70),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  if (mounted) Navigator.pop(context);
                },
                child: Text(_locale == 'ru' ? 'Выйти' : 'Exit', style: const TextStyle(color: Colors.white54)),
              ),
              TextButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  _socket.connect();
                  _emitJoinRoom();
                },
                child: Text(_locale == 'ru' ? 'Повторить' : 'Retry', style: const TextStyle(color: Color(0xFF6C63FF))),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF6C63FF)),
                onPressed: () {
                  Navigator.pop(ctx);
                  if (mounted) {
                    setState(() {
                      _hasJoinedRoom = true;
                    });
                    _socket.connect();
                    _emitJoinRoom();
                  }
                },
                child: Text(_locale == 'ru' ? 'Всё равно продолжить' : 'Continue anyway', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        );
      }
    });
  }

  @override
  void dispose() {
    _isDisposed = true;
    _usersNotifier.dispose();
    _syncTimer?.cancel();
    _controlsTimer?.cancel();
    _mkPlayer?.dispose();
    _webrtcManager?.stop();
    _localHttpServer?.close(force: true);
    _socket.disconnect();
    _socket.dispose();
    _urlInputController.dispose();
    _localPathController.dispose();
    _chatInputController.dispose();
    _chatScrollController.dispose();
    _chatFocusNode.dispose();
    super.dispose();
  }

  Future<http.Response> _httpGetWithRetry(Uri uri, {Map<String, String>? headers, Duration timeout = const Duration(seconds: 120)}) async {
    http.Response? lastResponse;
    for (int attempt = 1; attempt <= 3; attempt++) {
      try {
        final res = await http.get(uri, headers: headers).timeout(timeout);
        if (res.statusCode == 200) return res;
        lastResponse = res;
        if (attempt < 3 && (res.statusCode == 502 || res.statusCode == 503 || res.statusCode == 504)) {
          await Future.delayed(Duration(milliseconds: 1500 * attempt));
          continue;
        }
        return res;
      } catch (e) {
        if (attempt < 3) {
          await Future.delayed(Duration(milliseconds: 1500 * attempt));
        } else {
          rethrow;
        }
      }
    }
    return lastResponse!;
  }

  // Socket.io initialization and handlers
  void _initSocket() {
    _socket = io.io(widget.serverUrl, io.OptionBuilder()
      .setTransports(['websocket'])
      .enableAutoConnect()
      .enableReconnection()
      .setReconnectionDelay(1000)
      .setExtraHeaders({'bypass-tunnel-reminder': 'true'})
      .setQuery({'bypass-tunnel-reminder': 'true'})
      .build()
    );

    _socket.onConnectError((err) {
      debugPrint("Socket connect_error: $err");
    });
    _socket.onError((err) {
      debugPrint("Socket error: $err");
    });

    _webrtcManager = WebRTCManager(
      socket: _socket,
      roomId: widget.roomId,
      isHostResolver: () => _isHost,
    );
    _webrtcManager!.onStreamStarted = () {
      if (mounted) {
        setState(() {
          _isLiveStreaming = true;
        });
      }
      if (_isHost && _webrtcManager != null && _webrtcManager!.localStream != null) {
        for (var user in _users) {
          final id = user['id'] as String;
          if (id != _socket.id) {
            _webrtcManager!.createConnectionForViewer(id);
          }
        }
      }
    };
    _webrtcManager!.onRenderUpdated = () {
      if (mounted) {
        setState(() {});
      }
    };
    _webrtcManager!.onStreamStopped = () {
      if (mounted) setState(() { _isLiveStreaming = false; });
    };
    _webrtcManager!.initialize();

    _socket.on('stream-started', (_) {
      if (mounted) {
        setState(() {
          _isLiveStreaming = true;
        });
        _triggerControlsVisibility();
        try { _mkPlayer?.pause(); } catch (_) {}
        if (_isLocalStreamHost) {
          _webrtcManager?.setAudioMuted(_hostAudioMuted);
        } else {
          _webrtcManager?.setAudioMuted(false);
        }
        _socket.emit('new-viewer', {'roomId': widget.roomId, 'viewerId': _socket.id});
      }
    });
    _socket.on('stream-stopped', (_) {
      if (mounted) {
        setState(() {
          _isLiveStreaming = false;
          _isLocalStreamHost = false;
          _hostAudioMuted = true;
        });
        _webrtcManager?.clearRemoteStream();
        try { _localHttpServer?.close(force: true); } catch (_) {}
        _localHttpServer = null;
        try { _mkPlayer?.setVolume(100); } catch (_) {}
        try { _mkPlayer?.open(Media('')); } catch (_) {}
        try { _mkPlayer?.pause(); } catch (_) {}
      }
    });

    _socket.onConnect((_) {
      if (_isDisposed || !mounted) return;
      setState(() {
        _isConnected = true;
      });
      // Request ICE servers dynamically
      _socket.emit('get-ice-servers', {'roomId': widget.roomId});
      // Join the specified room
      _emitJoinRoom();
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
            title: Text(_locale == 'ru' ? 'Приватная комната' : 'Private Room', style: const TextStyle(color: Color(0xFF00F2FE))),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_locale == 'ru' ? 'Введите правильный пароль:' : 'Enter correct password:', style: const TextStyle(color: Colors.white)),
                const SizedBox(height: 12),
                TextField(
                  controller: pwController,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: Colors.black26,
                    hintText: _locale == 'ru' ? 'Пароль' : 'Password',
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
                child: Text(_locale == 'ru' ? 'Отмена' : 'Cancel', style: const TextStyle(color: Colors.white54)),
              ),
              ElevatedButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  _emitJoinRoom(passwordOverride: pwController.text.trim());
                },
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00F2FE)),
                child: Text(_locale == 'ru' ? 'Войти' : 'Join', style: const TextStyle(color: Colors.black)),
              ),
            ],
          ),
        );
        return;
      }

      _isDisposed = true; // Stop other connections from firing
      _socket.disconnect();
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF161426),
          title: Text(_locale == 'ru' ? 'Ошибка' : 'Error', style: const TextStyle(color: Colors.redAccent)),
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
      _usersNotifier.value = [];
    });

    // Handle user list updates
    _socket.on('room-users', (data) {
      if (_isDisposed || !mounted) return;

      final updatedUsers = (data as List).where((u) => !(u['username'] as String).endsWith('\u200B')).toList();
      String? detectedHost;
      for (var u in updatedUsers) {
        if (u['isHost'] == true) {
          detectedHost = u['username'] as String?;
          break;
        }
      }

      setState(() {
        _users = updatedUsers;
        if (detectedHost != null && detectedHost.isNotEmpty) {
          _hostUsername = detectedHost;
        }
      });
      _usersNotifier.value = List.from(updatedUsers);

      if (_webrtcManager != null && _isHost && _isLiveStreaming && _webrtcManager!.localStream != null) {
        final currentIds = _users.map((u) => u['id'] as String).toSet();
        for (var user in data) {
          final id = user['id'] as String;
          if (id != _socket.id && !currentIds.contains(id)) {
            _webrtcManager!.createConnectionForViewer(id);
          }
        }
      }
    });

    _socket.on('host-changed', (data) {
      if (_isDisposed || !mounted) return;
      final newHost = data is Map ? (data['hostUsername'] as String?) : null;
      if (newHost != null && newHost.isNotEmpty) {
        setState(() {
          _hostUsername = newHost;
        });
        final isMe = newHost.trim().toLowerCase() == widget.username.trim().toLowerCase();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              isMe
                  ? (_locale == 'ru' ? 'Вы стали хостом комнаты! 👑' : 'You are now the room host! 👑')
                  : (_locale == 'ru' ? 'Новый хост комнаты: $newHost 👑' : 'New room host: $newHost 👑'),
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
            ),
            backgroundColor: const Color(0xFF6C63FF),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    });

    _socket.on('user-joined', (data) {
      if (_isDisposed || !mounted) return;
      final newUser = data is Map<String, dynamic> ? data : (data is Map ? Map<String, dynamic>.from(data) : null);
      if (newUser != null) {
        final username = newUser['username'] as String? ?? '';
        if (!username.endsWith('\u200B')) {
          if (_webrtcManager != null && _isHost && _isLiveStreaming && _webrtcManager!.localStream != null) {
            _webrtcManager!.createConnectionForViewer(newUser['id'] as String);
          }
          setState(() {
            _users.removeWhere((u) => u['id'] == newUser['id']);
            _users.add(newUser);
          });
          _usersNotifier.value = List.from(_users);
        }
      }
    });

    _socket.on('user-left', (data) {
      if (_isDisposed || !mounted) return;
      final userId = data is Map ? data['id'] as String? : null;
      if (userId != null) {
        setState(() {
          _users.removeWhere((u) => u['id'] == userId);
        });
        _usersNotifier.value = List.from(_users);
      }
    });

    // Handle initial room state when joining
    _socket.on('room-state', (data) {
      if (_isDisposed || !mounted) return;
      if (data is! Map) return;
      final videoUrl = data['videoUrl']?.toString() ?? '';
      final videoName = data['videoName']?.toString() ?? 'No Video Loaded';
      final isPlaying = data['isPlaying'] == true;
      final calculatedTime = (data['calculatedTime'] is num) ? (data['calculatedTime'] as num).toDouble() : 0.0;
      final queueData = data['queue'] is List ? (data['queue'] as List<dynamic>) : <dynamic>[];
      final headers = data['headers'] is Map ? Map<String, dynamic>.from(data['headers'] as Map) : null;
      final isLive = data['isLiveStreaming'] == true;
      final hostUser = data['hostUsername']?.toString();
      final isHostState = data['isHost'] == true;
      final hostTok = data['hostToken']?.toString();

      if (isHostState && hostTok != null && hostTok.isNotEmpty) {
        _hostToken = hostTok;
        saveHostToken(widget.roomId, hostTok);
      } else if (!isHostState && _hostToken != null) {
        _hostToken = null;
        removeHostToken(widget.roomId);
      }

      setState(() {
        _hasJoinedRoom = true;
        _queue = queueData;
        _isLiveStreaming = isLive;
        if (hostUser != null && hostUser.isNotEmpty) {
          _hostUsername = hostUser;
        }
      });

      if (isLive) {
        setState(() {
          _isLiveStreaming = true;
        });
        _triggerControlsVisibility();
        try { _mkPlayer?.pause(); } catch (_) {}
        if (_isLocalStreamHost) {
          _webrtcManager?.setAudioMuted(_hostAudioMuted);
        } else {
          _webrtcManager?.setAudioMuted(false);
        }
        _socket.emit('new-viewer', {'roomId': widget.roomId, 'viewerId': _socket.id});
      } else if (videoUrl.isNotEmpty) {
        _setupVideoPlayer(videoUrl, videoName, startPlaying: isPlaying, startSeconds: calculatedTime, headers: headers);
      }
    });

    _socket.on('action-error', (data) {
      if (!mounted) return;
      final msg = data is Map ? (data['message'] ?? 'Действие отклонено') : 'Действие отклонено';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(msg.toString(), style: const TextStyle(color: Colors.white)),
          backgroundColor: Colors.redAccent,
          behavior: SnackBarBehavior.floating,
        ),
      );
    });

    // Handle video change event
    _socket.on('video-changed', (data) {
      if (_isDisposed || !mounted) return;
      if (data is! Map) return;
      final videoUrl = data['videoUrl']?.toString() ?? '';
      final videoName = data['videoName']?.toString() ?? 'No Video Loaded';
      final headers = data['headers'] is Map ? Map<String, dynamic>.from(data['headers'] as Map) : null;

      if (videoUrl.isEmpty) {
        try { _mkPlayer?.open(Media('')); } catch (_) {}
        try { _mkPlayer?.pause(); } catch (_) {}
        try { if (_webrtcManager != null) _webrtcManager!.remoteRenderer.srcObject = null; } catch (_) {}
        setState(() {
          _currentVideoUrl = '';
          _currentVideoName = 'No Video Loaded';
          _isLiveStreaming = false;
          _translators = [];
          _currentPageUrl = '';
        });
        return;
      }

      _setupVideoPlayer(videoUrl, videoName, startPlaying: true, headers: headers);
    });

    // Handle queue updates event
    _socket.on('queue-updated', (data) {
      if (_isDisposed || !mounted) return;
      setState(() {
        if (data is Map && data['queue'] is List) {
          _queue = data['queue'] as List<dynamic>;
        } else if (data is List) {
          _queue = data;
        } else {
          _queue = [];
        }
      });
    });

    // Handle Chat Message Broadcast
    _socket.on('chat-msg', (data) {
      if (_isDisposed || !mounted) return;
      if (data is! Map) return;

      final sender = data['username']?.toString() ?? 'Unknown';
      final text = data['text']?.toString() ?? '';
      final imageUrl = (data['imageUrl'] != null && data['imageUrl'].toString().isNotEmpty)
          ? data['imageUrl'].toString()
          : null;
      final replyTo = (data['replyTo'] is Map) ? Map<String, dynamic>.from(data['replyTo']) : null;
      final reactions = (data['reactions'] is Map) ? Map<String, dynamic>.from(data['reactions']) : <String, dynamic>{};

      // Do not display broadcaster join/leave notifications
      if (text.contains('(Broadcaster)') || text.contains('\u200B') || sender.contains('(Broadcaster)')) {
        return;
      }

      setState(() {
        _messages.add({
          'id': (data['id'] ?? '').toString(),
          'clientId': (data['clientId'] ?? '').toString(),
          'sender': sender,
          'text': text,
          'time': (data['timestamp'] ?? data['time'] ?? '').toString(),
          'imageUrl': imageUrl,
          'replyTo': replyTo,
          'reactions': reactions,
        });
      });

      // Notification
      if (Platform.isWindows) {
        windowManager.isFocused().then((isFocused) {
          if (!isFocused && mounted) {
            final notification = LocalNotification(
              title: sender,
              body: text.isNotEmpty ? text : (imageUrl != null ? '📷 Фото / GIF' : ''),
            );
            notification.onShow = () {};
            notification.onClose = (closeReason) {};
            notification.onClick = () {
              windowManager.show();
            };
            notification.show();
          }
        });
      }

      if (_chatSounds && sender != widget.username && sender != 'System' && sender != 'Система' && data['clientId'] != widget.clientId) {
        try {
          SystemSound.play(SystemSoundType.alert);
        } catch (_) {}
      }

      // Scroll to bottom if auto-scroll is enabled
      if (_autoScrollChat) {
        _scrollChatToBottom(animate: true);
      }
    });

    // Handle Chat Reaction Updated
    _socket.on('chat-reaction-updated', (data) {
      if (_isDisposed || !mounted || data is! Map) return;
      final messageId = data['messageId']?.toString();
      final reactions = (data['reactions'] is Map) ? Map<String, dynamic>.from(data['reactions']) : <String, dynamic>{};
      if (messageId != null && messageId.isNotEmpty) {
        setState(() {
          for (final m in _messages) {
            if (m['id'] == messageId) {
              m['reactions'] = reactions;
              break;
            }
          }
        });
      }
    });

    // Handle remote play event
    _socket.on('played', (data) {
      if (_isDisposed || !mounted) return;
      final time = (data is Map && data['time'] is num) ? (data['time'] as num).toDouble() : 0.0;
      _handleRemotePlay(time);
    });

    // Handle remote pause event
    _socket.on('paused', (data) {
      if (_isDisposed || !mounted) return;
      final time = (data is Map && data['time'] is num) ? (data['time'] as num).toDouble() : 0.0;
      _handleRemotePause(time);
    });

    // Handle remote seek event
    _socket.on('seeked', (data) {
      if (_isDisposed || !mounted) return;
      final time = (data is Map && data['time'] is num) ? (data['time'] as num).toDouble() : 0.0;
      _handleRemoteSeek(time);
    });

    // Handle continuous background sync
    _socket.on('sync-state-broadcast', (data) {
      if (_isDisposed || !mounted) return;
      if (data is! Map) return;
      final isPlaying = data['isPlaying'] == true;
      final currentTime = (data['currentTime'] is num) ? (data['currentTime'] as num).toDouble() : 0.0;
      _handlePeriodicSync(isPlaying, currentTime);
    });

    // Handle Chat History (e.g. on rejoin/reconnect)
    _socket.on('chat-history', (data) {
      if (_isDisposed || !mounted) return;
      if (data is! List) return;
      final history = data;
      setState(() {
        _messages.clear();
        for (final msg in history) {
          if (msg is Map) {
            final t = (msg['text'] ?? '').toString();
            final s = (msg['username'] ?? '').toString();
            if (t.contains('(Broadcaster)') || t.contains('\u200B') || s.contains('(Broadcaster)')) {
              continue;
            }
            final imgUrl = (msg['imageUrl'] != null && msg['imageUrl'].toString().isNotEmpty)
                ? msg['imageUrl'].toString()
                : null;
            final repTo = (msg['replyTo'] is Map) ? Map<String, dynamic>.from(msg['replyTo']) : null;
            final reacts = (msg['reactions'] is Map) ? Map<String, dynamic>.from(msg['reactions']) : <String, dynamic>{};
            _messages.add({
              'id': (msg['id'] ?? '').toString(),
              'clientId': (msg['clientId'] ?? '').toString(),
              'sender': (msg['username'] ?? 'Unknown').toString(),
              'text': (msg['text'] ?? '').toString(),
              'time': (msg['timestamp'] ?? msg['time'] ?? '').toString(),
              'imageUrl': imgUrl,
              'replyTo': repTo,
              'reactions': reacts,
            });
          }
        }
      });
      _scrollChatToBottom(animate: false);
    });

    // Handle Kicked from host
    _socket.on('kicked', (_) {
      if (_isDisposed || !mounted) return;
      _socket.disconnect();
      /* SnackBar disabled */
      Navigator.of(context).popUntil((route) => route.isFirst);
    });

    // Handle Kicked & Banned from host
    _socket.on('kicked-and-banned', (_) {
      if (_isDisposed || !mounted) return;
      _socket.disconnect();
      /* SnackBar disabled */
      Navigator.of(context).popUntil((route) => route.isFirst);
    });

    // Handle join error (e.g. banned)
    _socket.on('join-error', (data) {
      if (_isDisposed || !mounted) return;
      final errorMsg = data?.toString() ?? 'Error joining room';
      _socket.disconnect();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(errorMsg),
        backgroundColor: Colors.redAccent,
      ));
      Navigator.of(context).pop(); // Go back to connection page
    });

    // Connect AFTER all event handlers are registered
    _socket.connect();
    if (_socket.connected) {
      _emitJoinRoom();
    }

    // Auto-retry join-room after 3s if server response is slow
    Timer(const Duration(seconds: 3), () {
      if (mounted && !_hasJoinedRoom) {
        if (!_socket.connected) {
          _socket.connect();
        }
        _emitJoinRoom();
      }
    });
  }

  static const List<Map<String, String>> _popularGifs = [
    {'title': 'Попкорн', 'url': 'https://media.giphy.com/media/gl0mkIZOW6Nwc/giphy.gif'},
    {'title': 'Кот кивает', 'url': 'https://media.giphy.com/media/jpbnoe3UIa8TU8LM13/giphy.gif'},
    {'title': 'Аплодисменты', 'url': 'https://media.giphy.com/media/nbvFVPiEiJH6Q/giphy.gif'},
    {'title': 'Шок', 'url': 'https://media.giphy.com/media/26ufdipQqU2lhNA4g/giphy.gif'},
    {'title': 'Смех', 'url': 'https://media.giphy.com/media/10JhviFuU2gWD6/giphy.gif'},
    {'title': 'Палец вверх', 'url': 'https://media.giphy.com/media/111ebonMs90YLu/giphy.gif'},
    {'title': 'Фейспалм', 'url': 'https://media.giphy.com/media/3og0INyCmHlNylks9O/giphy.gif'},
    {'title': 'Танец', 'url': 'https://media.giphy.com/media/blSTtZehjAZ8I/giphy.gif'},
    {'title': 'Сердечки', 'url': 'https://media.giphy.com/media/M90mJvfWfd5mbUuULX/giphy.gif'},
    {'title': 'Крутой', 'url': 'https://media.giphy.com/media/xT0xeJpnrWC4XWblEk/giphy.gif'},
    {'title': 'Огонь', 'url': 'https://media.giphy.com/media/yr7n0u3qzO9nG/giphy.gif'},
    {'title': 'Слёзы', 'url': 'https://media.giphy.com/media/d2lcHJTG5Tscg/giphy.gif'},
  ];

  static const List<String> _quickEmojis = ['❤️', '👍', '👎', '🔥', '😂', '😮', '😢', '👏', '🎉'];

  int _lastChatSentMs = 0;
  Offset? _lastChatTapPosition;

  void _scrollChatToBottom({bool animate = true}) {
    if (!_chatScrollController.hasClients) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_chatScrollController.hasClients) return;
      void step(int attempts) {
        if (!_chatScrollController.hasClients || attempts > 8) return;
        final pos = _chatScrollController.position;
        final max = pos.maxScrollExtent;
        final current = pos.pixels;
        if ((max - current).abs() > 2.0) {
          if (animate && (max - current) < 800) {
            _chatScrollController.animateTo(
              max,
              duration: const Duration(milliseconds: 120),
              curve: Curves.easeOut,
            ).then((_) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (_chatScrollController.hasClients &&
                    _chatScrollController.position.pixels < _chatScrollController.position.maxScrollExtent - 2) {
                  step(attempts + 1);
                }
              });
            });
          } else {
            _chatScrollController.jumpTo(max);
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (_chatScrollController.hasClients &&
                  _chatScrollController.position.pixels < _chatScrollController.position.maxScrollExtent - 2) {
                step(attempts + 1);
              }
            });
          }
        }
      }
      step(0);
    });
  }

  // Send chat message
  void _sendChatMessage({String? imageUrl, String? overrideText}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastChatSentMs < 200) return; // Rate limit: max 1 message per 200ms
    _lastChatSentMs = now;
    final text = overrideText ?? _chatInputController.text.trim();
    if ((text.isEmpty && (imageUrl == null || imageUrl.isEmpty)) || text.length > 500) return;
    _socket.emit('chat-msg', {
      'roomId': widget.roomId,
      'username': widget.username,
      'text': text,
      'clientId': widget.clientId,
      'imageUrl': imageUrl,
      'replyTo': _replyingTo,
    });
    if (overrideText == null) {
      _chatInputController.clear();
    }
    if (mounted && _replyingTo != null) {
      setState(() {
        _replyingTo = null;
      });
    }
    _chatFocusNode.requestFocus(); // Re-focus chat text field instantly
    _scrollChatToBottom(animate: true);
  }

  void _toggleReaction(String messageId, String emoji) {
    if (messageId.isEmpty || emoji.isEmpty) return;
    _socket.emit('chat-reaction', {
      'roomId': widget.roomId,
      'messageId': messageId,
      'emoji': emoji,
      'username': widget.username,
      'clientId': widget.clientId,
    });
  }

  void _startReply(Map<String, dynamic> message) {
    setState(() {
      _replyingTo = {
        'id': message['id'] ?? '',
        'sender': message['sender'] ?? 'Unknown',
        'text': (message['text'] != null && (message['text'] as String).isNotEmpty)
            ? message['text']
            : (message['imageUrl'] != null ? '📷 Фото / GIF' : ''),
      };
    });
    _chatFocusNode.requestFocus();
  }

  Future<void> _uploadAndSendImageBytes(Uint8List bytes, String filename, {String? text}) async {
    try {
      if (bytes.lengthInBytes > 15 * 1024 * 1024) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(_locale == 'ru' ? 'Файл слишком большой (макс 15 МБ)' : 'File too large (max 15MB)'),
              backgroundColor: Colors.redAccent,
            ),
          );
        }
        return;
      }

      setState(() => _isUploadingImage = true);

      final base64Data = base64Encode(bytes);
      final serverBase = widget.serverUrl.replaceAll('wss://', 'https://').replaceAll('ws://', 'http://');
      final uri = Uri.parse('$serverBase/api/upload-chat-image');

      final resp = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'imageBase64': base64Data,
          'filename': filename,
        }),
      ).timeout(const Duration(seconds: 25));

      if (mounted) setState(() => _isUploadingImage = false);

      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        final imageUrl = data['url']?.toString();
        if (imageUrl != null && imageUrl.isNotEmpty) {
          _sendChatMessage(imageUrl: imageUrl, overrideText: text);
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(_locale == 'ru' ? 'Ошибка загрузки фото' : 'Failed to upload photo'),
              backgroundColor: Colors.redAccent,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isUploadingImage = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${_locale == 'ru' ? 'Ошибка' : 'Error'}: $e'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  Future<void> _pickAndUploadImage() async {
    try {
      final file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: ['png', 'jpg', 'jpeg', 'gif', 'webp'],
      );
      if (file == null) return;
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) return;
      await _uploadAndSendImageBytes(bytes, file.name);
    } catch (e) {
      debugPrint('Error picking image: $e');
    }
  }

  void _showPastedImageConfirmDialog(Uint8List imageBytes, {String filename = 'clipboard.png'}) {
    final captionController = TextEditingController(text: _chatInputController.text.trim());
    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: const Color(0xFF161426),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: Color(0xFF00F2FE), width: 1),
          ),
          title: Row(
            children: [
              const Icon(Icons.paste_rounded, color: Color(0xFF00F2FE), size: 20),
              const SizedBox(width: 8),
              Text(
                _locale == 'ru' ? 'Отправить изображение?' : 'Send pasted image?',
                style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 240),
                  child: Image.memory(
                    imageBytes,
                    fit: BoxFit.contain,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: captionController,
                autofocus: true,
                style: const TextStyle(color: Colors.white, fontSize: 13),
                decoration: InputDecoration(
                  hintText: _locale == 'ru' ? 'Добавить подпись (необязательно)...' : 'Add caption (optional)...',
                  hintStyle: const TextStyle(color: Colors.white38, fontSize: 12),
                  filled: true,
                  fillColor: Colors.white.withOpacity(0.04),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(color: Colors.white.withOpacity(0.1)),
                  ),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                ),
                onSubmitted: (_) {
                  Navigator.of(ctx).pop();
                  final text = captionController.text.trim();
                  _chatInputController.clear();
                  _uploadAndSendImageBytes(imageBytes, filename, text: text.isNotEmpty ? text : null);
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(
                _locale == 'ru' ? 'Отмена' : 'Cancel',
                style: const TextStyle(color: Colors.white54),
              ),
            ),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00F2FE),
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              icon: const Icon(Icons.send_rounded, size: 16),
              label: Text(
                _locale == 'ru' ? 'Отправить' : 'Send',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              onPressed: () {
                Navigator.of(ctx).pop();
                final text = captionController.text.trim();
                _chatInputController.clear();
                _uploadAndSendImageBytes(imageBytes, filename, text: text.isNotEmpty ? text : null);
              },
            ),
          ],
        );
      },
    );
  }

  Future<void> _handlePasteFromClipboard() async {
    // 1. Check if an image is in the clipboard (e.g. screenshot Snipping Tool / Copy image)
    try {
      final imageBytes = await Pasteboard.image;
      if (imageBytes != null && imageBytes.isNotEmpty) {
        _showPastedImageConfirmDialog(imageBytes);
        return;
      }
    } catch (e) {
      debugPrint('Pasteboard image check error: $e');
    }

    // 2. Check if user copied file(s) in Explorer
    try {
      final files = await Pasteboard.files();
      if (files.isNotEmpty) {
        final first = files.first;
        final lower = first.toLowerCase();
        if (lower.endsWith('.png') || lower.endsWith('.jpg') || lower.endsWith('.jpeg') || lower.endsWith('.gif') || lower.endsWith('.webp')) {
          final file = File(first);
          if (await file.exists()) {
            final bytes = await file.readAsBytes();
            _showPastedImageConfirmDialog(bytes, filename: file.uri.pathSegments.last);
            return;
          }
        }
      }
    } catch (e) {
      debugPrint('Pasteboard files check error: $e');
    }

    // 3. Fallback: text paste
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      if (data?.text != null && data!.text!.isNotEmpty) {
        final text = data.text!;
        final val = _chatInputController.value;
        final selection = val.selection;
        if (selection.isValid && selection.start >= 0) {
          final newText = val.text.replaceRange(selection.start, selection.end, text);
          _chatInputController.value = TextEditingValue(
            text: newText,
            selection: TextSelection.collapsed(offset: selection.start + text.length),
          );
        } else {
          _chatInputController.text += text;
          _chatInputController.selection = TextSelection.collapsed(offset: _chatInputController.text.length);
        }
      }
    } catch (_) {}
  }

  void _showMediaAttachmentPicker() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E2028),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  _locale == 'ru' ? 'Прикрепить к сообщению' : 'Attach to message',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 16),
                ListTile(
                  leading: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF00F2FE).withOpacity(0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.photo_library_outlined, color: Color(0xFF00F2FE)),
                  ),
                  title: Text(_locale == 'ru' ? 'Загрузить фото или GIF с устройства' : 'Upload photo or GIF from device', style: const TextStyle(color: Colors.white, fontSize: 13)),
                  subtitle: Text(_locale == 'ru' ? 'PNG, JPG, GIF, WebP' : 'PNG, JPG, GIF, WebP', style: TextStyle(color: Colors.white.withOpacity(0.4), fontSize: 11)),
                  onTap: () {
                    Navigator.pop(ctx);
                    _pickAndUploadImage();
                  },
                ),
                ListTile(
                  leading: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.pinkAccent.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.gif_box_outlined, color: Colors.pinkAccent),
                  ),
                  title: Text(_locale == 'ru' ? 'Популярные GIF-реакции' : 'Popular GIF reactions', style: const TextStyle(color: Colors.white, fontSize: 13)),
                  subtitle: Text(_locale == 'ru' ? 'Выбрать мем или эмоцию' : 'Choose a meme or reaction', style: TextStyle(color: Colors.white.withOpacity(0.4), fontSize: 11)),
                  onTap: () {
                    Navigator.pop(ctx);
                    _showPopularGifsDialog();
                  },
                ),
                ListTile(
                  leading: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.amberAccent.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.link_rounded, color: Colors.amberAccent),
                  ),
                  title: Text(_locale == 'ru' ? 'Вставить ссылку на изображение/GIF' : 'Paste image/GIF URL', style: const TextStyle(color: Colors.white, fontSize: 13)),
                  subtitle: Text(_locale == 'ru' ? 'Прямая ссылка на картинку в интернете' : 'Direct link to image on web', style: TextStyle(color: Colors.white.withOpacity(0.4), fontSize: 11)),
                  onTap: () {
                    Navigator.pop(ctx);
                    _showImageUrlDialog();
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showPopularGifsDialog() {
    showDialog(
      context: context,
      builder: (ctx) {
        return Dialog(
          backgroundColor: const Color(0xFF1E2028),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          child: Container(
            width: 440,
            height: 480,
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.gif_box_outlined, color: Color(0xFF00F2FE), size: 22),
                        const SizedBox(width: 8),
                        Text(
                          _locale == 'ru' ? 'Популярные GIF' : 'Popular GIFs',
                          style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white54, size: 20),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: GridView.builder(
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      crossAxisSpacing: 10,
                      mainAxisSpacing: 10,
                      childAspectRatio: 1.25,
                    ),
                    itemCount: _popularGifs.length,
                    itemBuilder: (context, idx) {
                      final item = _popularGifs[idx];
                      return InkWell(
                        onTap: () {
                          Navigator.pop(ctx);
                          _sendChatMessage(imageUrl: item['url']);
                        },
                        borderRadius: BorderRadius.circular(12),
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.black26,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: Colors.white12),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              Image.network(
                                item['url']!,
                                fit: BoxFit.cover,
                                loadingBuilder: (context, child, progress) {
                                  if (progress == null) return child;
                                  return const Center(child: CircularProgressIndicator(strokeWidth: 2));
                                },
                                errorBuilder: (_, __, ___) => const Center(
                                  child: Icon(Icons.broken_image, color: Colors.white38),
                                ),
                              ),
                              Positioned(
                                bottom: 0,
                                left: 0,
                                right: 0,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 6),
                                  color: Colors.black.withOpacity(0.65),
                                  child: Text(
                                    item['title'] ?? '',
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showImageUrlDialog() {
    final textController = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1E2028),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text(
            _locale == 'ru' ? 'Ссылка на изображение или GIF' : 'Image or GIF URL',
            style: const TextStyle(color: Colors.white, fontSize: 16),
          ),
          content: TextField(
            controller: textController,
            autofocus: true,
            style: const TextStyle(color: Colors.white, fontSize: 13),
            decoration: InputDecoration(
              hintText: 'https://.../image.png (или .gif, .webp)',
              hintStyle: TextStyle(color: Colors.white.withOpacity(0.35), fontSize: 12),
              filled: true,
              fillColor: Colors.black26,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(_locale == 'ru' ? 'Отмена' : 'Cancel', style: const TextStyle(color: Colors.white54)),
            ),
            ElevatedButton(
              onPressed: () {
                final url = textController.text.trim();
                if (url.isNotEmpty && (url.startsWith('http://') || url.startsWith('https://'))) {
                  Navigator.pop(ctx);
                  _sendChatMessage(imageUrl: url);
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00F2FE),
                foregroundColor: Colors.black,
              ),
              child: Text(_locale == 'ru' ? 'Отправить' : 'Send', style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        );
      },
    );
  }

  void _showFullscreenImage(String imageUrl) {
    showDialog(
      context: context,
      builder: (ctx) {
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.all(16),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Container(
                constraints: const BoxConstraints(maxWidth: 800, maxHeight: 600),
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(color: Colors.black.withOpacity(0.8), blurRadius: 20),
                  ],
                ),
                clipBehavior: Clip.antiAlias,
                child: Image.network(
                  imageUrl,
                  fit: BoxFit.contain,
                  loadingBuilder: (context, child, progress) {
                    if (progress == null) return child;
                    return const Center(child: CircularProgressIndicator(strokeWidth: 2));
                  },
                  errorBuilder: (_, __, ___) => Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        _locale == 'ru' ? 'Не удалось загрузить изображение' : 'Failed to load image',
                        style: const TextStyle(color: Colors.white70),
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 8,
                right: 8,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.open_in_browser, color: Colors.white),
                      tooltip: _locale == 'ru' ? 'Открыть в браузере' : 'Open in browser',
                      onPressed: () => launchUrl(Uri.parse(imageUrl)),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // Kick user (Host only)
  void _kickUser(String targetSocketId) {
    _socket.emit('kick-user', {
      'roomId': widget.roomId,
      'targetSocketId': targetSocketId,
    });
    setState(() {
      _users.removeWhere((u) => u['id'] == targetSocketId);
    });
    _usersNotifier.value = List.from(_users);
  }

  // Ban user (Host only)
  void _banUser(String targetSocketId) {
    _socket.emit('ban-user', {
      'roomId': widget.roomId,
      'targetSocketId': targetSocketId,
    });
    setState(() {
      _users.removeWhere((u) => u['id'] == targetSocketId);
    });
    _usersNotifier.value = List.from(_users);
  }

  // Set up video player with a specific URL (uses media_kit which supports HLS natively)
  Future<void> _setupVideoPlayer(String url, String name, {bool startPlaying = false, double startSeconds = 0.0, Map<String, dynamic>? headers}) async {
    if (_isDisposed || !mounted) return;

    setState(() {
      _currentVideoUrl = url;
      _currentVideoName = name;
    });

    _triggerControlsVisibility();

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
        /* SnackBar disabled */
      }
      final streamUrl = await getYoutubeStreamUrl(url);
      if (streamUrl != null) {
        playUrl = streamUrl;
      } else {
        if (mounted) {
          /* SnackBar disabled */
        }
      }
    } else if (lowercaseUrl.startsWith('http') &&
               !url.contains('/video?path=') &&
               !url.contains('/proxy/') &&
               !url.contains('/live-stream/') &&
               !url.contains('/live') &&
               !lowercaseUrl.contains('.mp4') &&
               !lowercaseUrl.contains('.m3u8') &&
               !lowercaseUrl.contains('.mkv') &&
               !lowercaseUrl.contains('.webm') &&
               !lowercaseUrl.contains('vkuser') &&
               !lowercaseUrl.contains('vk-cdn')) {
      // Non-YouTube web link: extract via server
      if (mounted) {
        /* SnackBar disabled */
      }
      try {
        final extractUri = Uri.parse('${widget.serverUrl}/extract?url=${Uri.encodeComponent(url)}');
        final response = await _httpGetWithRetry(
          extractUri,
          headers: {'bypass-tunnel-reminder': 'true'},
        );

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
          /* SnackBar disabled */
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
    final sanitizedLogUrl = () {
      try {
        final uri = Uri.parse(playUrl);
        return '${uri.scheme}://${uri.host}${uri.path}';
      } catch (_) {
        return '<url>';
      }
    }();
    debugPrint('[media_kit] Opening: $sanitizedLogUrl');

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
      /* SnackBar disabled */
    }
  }


  Future<String?> getYoutubeStreamUrl(String youtubeUrl) async {
    try {
      final appData = Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path;
      final dir = Directory('$appData\\RaveStreamer');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final ytDlp = '${dir.path}\\yt-dlp.exe';

      if (!File(ytDlp).existsSync()) {
        debugPrint('Downloading yt-dlp.exe to $ytDlp');
        final dlpUri = Uri.parse('https://github.com/yt-dlp/yt-dlp-nightly-builds/releases/latest/download/yt-dlp.exe');
        if (dlpUri.host != 'github.com' || !dlpUri.path.startsWith('/yt-dlp/')) {
          throw Exception('Untrusted yt-dlp source');
        }
        final response = await http.get(dlpUri);
        if (response.statusCode == 200 && response.bodyBytes.length > 500000) {
          await File(ytDlp).writeAsBytes(response.bodyBytes);
        } else {
          throw Exception('Failed to download valid yt-dlp binary');
        }
      }

      debugPrint('Running local yt-dlp with Chrome cookies...');
      var result = await Process.run(ytDlp, ['--dump-json', '-f', 'b[ext=mp4]/b/best', '--no-warnings', '--extractor-args', 'youtube:player_client=ios', '--cookies-from-browser', 'chrome', youtubeUrl]);

      if (result.exitCode != 0) {
        debugPrint('Chrome cookies failed, trying Edge cookies...');
        result = await Process.run(ytDlp, ['--dump-json', '-f', 'b[ext=mp4]/b/best', '--no-warnings', '--extractor-args', 'youtube:player_client=ios', '--cookies-from-browser', 'edge', youtubeUrl]);
      }

      if (result.exitCode != 0) {
        debugPrint('Cookies failed, trying without cookies...');
        result = await Process.run(ytDlp, ['--dump-json', '-f', 'b[ext=mp4]/b/best', '--no-warnings', '--extractor-args', 'youtube:player_client=ios', youtubeUrl]);
      }

      if (result.exitCode == 0) {
        final data = jsonDecode(result.stdout as String);
        debugPrint('Successfully extracted YouTube URL via local yt-dlp!');
        return data['url'] as String;
      } else {
        debugPrint('Local yt-dlp failed: ${result.stderr}');
      }
    } catch (e) {
      debugPrint('Error with local yt-dlp: $e');
    }

    debugPrint('Trying Invidious API fallback on client...');
    final invidiousInstances = ['https://vid.puffyan.us', 'https://invidious.jing.rocks', 'https://inv.tux.pizza', 'https://invidious.protokolla.fi', 'https://inv.nadeko.net', 'https://invidious.nerdvpn.de'];
    String videoIdStr = youtubeUrl;
    try {
      videoIdStr = VideoId(youtubeUrl).value;
    } catch(_) {
      if (youtubeUrl.contains('v=')) {
        videoIdStr = youtubeUrl.split('v=')[1].split('&')[0];
      }
    }

    for (final inst in invidiousInstances) {
      try {
        final res = await http.get(Uri.parse('$inst/api/v1/videos/$videoIdStr')).timeout(const Duration(seconds: 4));
        if (res.statusCode == 200) {
          final data = jsonDecode(res.body);
          if (data['formatStreams'] != null && (data['formatStreams'] as List).isNotEmpty) {
            final streams = data['formatStreams'] as List;
            var stream = streams.firstWhere((s) => (s['resolution'] ?? '').contains('1080'), orElse: () => null);
            stream ??= streams.firstWhere((s) => (s['resolution'] ?? '').contains('720'), orElse: () => streams.first);
            if (stream != null && stream['url'] != null) {
              debugPrint('Client Invidious API fallback successful on $inst.');
              return stream['url'] as String;
            }
          }
        }
      } catch (_) {}
    }

    debugPrint('Trying Piped API fallback on client...');
    final pipedInstances = ['https://pipedapi.kavin.rocks', 'https://api.piped.projectsegfau.lt', 'https://pipedapi.in.projectsegfau.lt', 'https://pipedapi.us.projectsegfau.lt', 'https://piped-api.garudalinux.org'];
    for (final inst in pipedInstances) {
      try {
        final res = await http.get(Uri.parse('$inst/streams/$videoIdStr')).timeout(const Duration(seconds: 4));
        if (res.statusCode == 200) {
          final data = jsonDecode(res.body);
          if (data['videoStreams'] != null && (data['videoStreams'] as List).isNotEmpty) {
            final streams = data['videoStreams'] as List;
            var stream = streams.firstWhere((s) => s['videoOnly'] == false && (s['quality'] ?? '').contains('1080'), orElse: () => null);
            stream ??= streams.firstWhere((s) => s['videoOnly'] == false && (s['quality'] ?? '').contains('720'), orElse: () => null);
            stream ??= streams.firstWhere((s) => s['videoOnly'] == false, orElse: () => streams.first);
            if (stream != null && stream['url'] != null) {
              debugPrint('Client Piped API fallback successful on $inst.');
              return stream['url'] as String;
            }
          }
        }
      } catch (_) {}
    }

    // Fallback to youtube_explode
    final yt = YoutubeExplode();
    try {
      String videoIdStr;
      try {
        final videoId = VideoId(youtubeUrl);
        videoIdStr = videoId.value;
      } catch (_) {
        videoIdStr = youtubeUrl;
      }

      debugPrint('Fetching YouTube manifest for ID: $videoIdStr');
      final manifest = await yt.videos.streamsClient.getManifest(videoIdStr);

      debugPrint('Muxed streams count: ${manifest.muxed.length}');
      if (manifest.muxed.isNotEmpty) {
        MuxedStreamInfo? selectedStream;
        if (_preferredQuality != 'Auto') {
          try {
            final targetHeight = int.parse(_preferredQuality.replaceAll('p', ''));
            final streams = manifest.muxed.where((s) => s.videoResolution.height <= targetHeight).toList();
            if (streams.isNotEmpty) {
              streams.sort((a, b) => b.videoResolution.height.compareTo(a.videoResolution.height));
              selectedStream = streams.first;
            }
          } catch (_) {}
        }
        selectedStream ??= manifest.muxed.withHighestBitrate();

        final directUrl = selectedStream.url.toString();
        debugPrint('Successfully extracted YouTube muxed stream URL: $directUrl');
        return directUrl;
      } else {
        debugPrint('Muxed streams list is empty. Trying fallback.');
        if (manifest.videoOnly.isNotEmpty) {
          final streamInfo = manifest.videoOnly.withHighestBitrate();
          final directUrl = streamInfo.url.toString();
          debugPrint('Using video-only stream fallback: $directUrl');
          return directUrl;
        }
      }
    } catch (e) {
      debugPrint('Error extracting YouTube URL: $e');
    } finally {
      yt.close();
    }

    // Ultimate fallback: server-side extraction on VPS
    try {
      final extractUri = Uri.parse('${widget.serverUrl}/extract?url=${Uri.encodeComponent(youtubeUrl)}');
      final res = await http.get(extractUri, headers: {'bypass-tunnel-reminder': 'true'}).timeout(const Duration(seconds: 15));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        if (data['success'] == true && data['url'] != null) {
          debugPrint('VPS extraction for YouTube successful!');
          return data['url'] as String;
        }
      }
    } catch (e) {
      debugPrint('VPS fallback error: $e');
    }

    return null;
  }

  void _clearPlayer() {
    _socket.emit('clear-player', {
      'roomId': widget.roomId
    });
    _socket.emit('video-change', {
      'roomId': widget.roomId,
      'videoUrl': '',
      'videoName': 'No Video Loaded'
    });
    _socket.emit('stop-stream', {
      'roomId': widget.roomId
    });
    _urlInputController.clear();
    try { _mkPlayer?.open(Media('')); } catch (_) {}
    try { _mkPlayer?.pause(); } catch (_) {}
    try { if (_webrtcManager != null) _webrtcManager!.remoteRenderer.srcObject = null; } catch (_) {}
    setState(() {
      _currentVideoUrl = '';
      _currentVideoName = 'No Video Loaded';
      _isLiveStreaming = false;
      _translators = [];
      _currentPageUrl = '';
    });
  }

  // Send video change event to server
  void _changeVideo(String url, String name) async {
    if (url.trim().isEmpty) return;

    String finalUrl = url.trim();
    String finalName = name.trim().isEmpty ? 'Web Stream' : name.trim();

    final lowercaseUrl = finalUrl.toLowerCase();
    final isWebLink = lowercaseUrl.startsWith('http://') || lowercaseUrl.startsWith('https://');

    if (!isWebLink) {
      if (!mounted) return;
      /* SnackBar disabled */
      return;
    }

    Map<String, dynamic>? finalHeaders;

    if (isWebLink &&
        !finalUrl.contains('/video?path=') &&
        !finalUrl.contains('/proxy/') &&
        !finalUrl.contains('/live-stream/') &&
        !finalUrl.contains('/live') &&
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
        /* SnackBar disabled */

        try {
          final extractUri = Uri.parse('${widget.serverUrl}/extract?url=${Uri.encodeComponent(url)}');
          final response = await _httpGetWithRetry(
            extractUri,
            headers: {'bypass-tunnel-reminder': 'true'},
          );

          if (response.statusCode == 200) {
            final data = jsonDecode(response.body) as Map<String, dynamic>;
            if (data['success'] == true && data['url'] != null) {
              // URL is already a /proxy/hls URL — no auth headers needed from client
              final rawUrl = data['url'] as String;
              // If it's a relative proxy path, make it absolute with the server URL
              if (rawUrl.startsWith('/')) {
                final serverBase = widget.serverUrl.replaceAll('wss://', 'https://').replaceAll('ws://', 'http://');
                finalUrl = '$serverBase$rawUrl';
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
          /* SnackBar disabled */
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
        /* SnackBar disabled */

        try {
          final extractUri = Uri.parse('${widget.serverUrl}/extract?url=${Uri.encodeComponent(url)}');
          final response = await _httpGetWithRetry(
            extractUri,
            headers: {'bypass-tunnel-reminder': 'true'},
          );

          if (response.statusCode == 200) {
            final data = jsonDecode(response.body) as Map<String, dynamic>;
            if (data['success'] == true && data['url'] != null) {
              final rawUrl = data['url'] as String;
              if (rawUrl.startsWith('/')) {
                final serverBase = widget.serverUrl.replaceAll('wss://', 'https://').replaceAll('ws://', 'http://');
                finalUrl = '$serverBase$rawUrl';
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
          /* SnackBar disabled */
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
    /* SnackBar disabled */
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
      /* SnackBar disabled */
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
      /* SnackBar disabled */
    }
  }


  void _skipVideo() {
    if (!_isHost) return;
    _socket.emit('skip-video', {
      'roomId': widget.roomId,
    });
  }

  // Handle local user control events and broadcast them
  void _localPlay() {
    if (!_isHost) return;
    if (_mkPlayer == null) return;
    _mkPlayer!.play();
    _socket.emit('play', {
      'roomId': widget.roomId,
      'time': _mkPlayer!.state.position.inMilliseconds / 1000.0,
    });
  }

  void _localPause() {
    if (!_isHost) return;
    if (_mkPlayer == null) return;
    _mkPlayer!.pause();
    _socket.emit('pause', {
      'roomId': widget.roomId,
      'time': _mkPlayer!.state.position.inMilliseconds / 1000.0,
    });
  }

  int _lastSeekSentMs = 0;
  void _localSeek(double seconds) {
    if (!_isHost) return;
    if (_mkPlayer == null) return;
    _isIncomingUpdate = true;
    _mkPlayer!.seek(Duration(milliseconds: (seconds * 1000).toInt())).then((_) {
      _isIncomingUpdate = false;
    });
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastSeekSentMs < 100) return; // Rate limit: max 10 seek emits/sec
    _lastSeekSentMs = now;
    _socket.emit('seek', {
      'roomId': widget.roomId,
      'time': seconds,
    });
  }

  // Host sends its current playing details so others can synchronize to it
  void _sendPeriodicSync() {
    if (_mkPlayer == null || !_isConnected) return;

    if (_isHost) {
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

  // Adaptive Drift Synchronization (Smooth micro-rate speed adjustment vs hard seeks)
  void _handlePeriodicSync(bool serverIsPlaying, double serverSeconds) {
    if (_mkPlayer == null || _isIncomingUpdate) return;
    if (_isHost) return;

    final duration = _mkPlayer!.state.duration;
    final position = _mkPlayer!.state.position;
    final isAtEnd = duration.inMilliseconds > 0 && position.inMilliseconds >= duration.inMilliseconds - 100;

    // Align playing state
    if (serverIsPlaying && !_mkPlayer!.state.playing && !isAtEnd) {
      _mkPlayer!.play();
    } else if (!serverIsPlaying && _mkPlayer!.state.playing) {
      _mkPlayer!.pause();
      if (_mkPlayer!.state.playbackRate != 1.0) {
        _mkPlayer!.setPlaybackRate(1.0);
      }
    }

    final localSeconds = _mkPlayer!.state.position.inMilliseconds / 1000.0;
    final diff = serverSeconds - localSeconds; // positive = local is behind, negative = local is ahead
    final drift = diff.abs();

    if (!serverIsPlaying) {
      // When paused, if drift is more than 0.3s, just seek to align frames exactly
      if (drift > 0.3) {
        _isIncomingUpdate = true;
        _mkPlayer!.seek(Duration(milliseconds: (serverSeconds * 1000).toInt())).then((_) {
          _isIncomingUpdate = false;
        });
      }
      return;
    }

    // When playing:
    if (drift > _syncToleranceSec) {
      // Large drift: hard seek
      _isIncomingUpdate = true;
      _mkPlayer!.seek(Duration(milliseconds: (serverSeconds * 1000).toInt())).then((_) {
        _isIncomingUpdate = false;
        _mkPlayer!.setPlaybackRate(1.0);
      });
    } else if (drift > 0.15) {
      // Micro drift: smoothly adjust playback speed without stuttering audio or video
      if (diff > 0) {
        // Local is behind: speed up slightly (1.05x to 1.08x)
        final targetRate = diff > 1.0 ? 1.08 : 1.05;
        if ((_mkPlayer!.state.playbackRate - targetRate).abs() > 0.01) {
          _mkPlayer!.setPlaybackRate(targetRate);
        }
      } else {
        // Local is ahead: slow down slightly (0.95x to 0.92x)
        final targetRate = diff < -1.0 ? 0.92 : 0.95;
        if ((_mkPlayer!.state.playbackRate - targetRate).abs() > 0.01) {
          _mkPlayer!.setPlaybackRate(targetRate);
        }
      }
    } else {
      // In-sync (within 150ms): ensure normal 1.0x playback rate
      if (_mkPlayer!.state.playbackRate != 1.0) {
        _mkPlayer!.setPlaybackRate(1.0);
      }
    }
  }

  // -------------------------------------------------------------
  // Subtitles & Audio Track Selector Dialog
  // -------------------------------------------------------------
  void _showTracksDialog() {
    if (_mkPlayer == null) return;
    final audioTracks = _mkPlayer!.state.audioTracks;
    final subtitleTracks = _mkPlayer!.state.subtitleTracks;

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF161426),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.white24,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        const Icon(Icons.subtitles_rounded, color: Color(0xFF00F2FE), size: 20),
                        const SizedBox(width: 8),
                        Text(
                          _locale == 'ru' ? 'Субтитры и Аудио' : 'Subtitles & Audio',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    // Audio Tracks Section
                    Text(
                      _locale == 'ru' ? 'АУДИОДОРОЖКА' : 'AUDIO TRACK',
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1,
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (audioTracks.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                          _locale == 'ru' ? 'Основная звуковая дорожка (по умолчанию)' : 'Default audio track',
                          style: const TextStyle(color: Colors.white70, fontSize: 13),
                        ),
                      )
                    else
                      ...audioTracks.map((track) {
                        final isSelected = track.id == _mkPlayer!.state.currentAudioTrack;
                        return InkWell(
                          onTap: () {
                            _mkPlayer!.setAudioTrack(track.id);
                            setSheetState(() {});
                            setState(() {});
                          },
                          borderRadius: BorderRadius.circular(10),
                          child: Container(
                            margin: const EdgeInsets.only(bottom: 6),
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                            decoration: BoxDecoration(
                              color: isSelected ? const Color(0xFF00F2FE).withOpacity(0.15) : Colors.white.withOpacity(0.04),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: isSelected ? const Color(0xFF00F2FE) : Colors.transparent,
                                width: 1,
                              ),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  isSelected ? Icons.check_circle_rounded : Icons.radio_button_unchecked,
                                  color: isSelected ? const Color(0xFF00F2FE) : Colors.white38,
                                  size: 18,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    track.name,
                                    style: TextStyle(
                                      color: isSelected ? Colors.white : Colors.white70,
                                      fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      }),
                    const SizedBox(height: 16),
                    // Subtitles Section
                    Text(
                      _locale == 'ru' ? 'СУБТИТРЫ' : 'SUBTITLES',
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1,
                      ),
                    ),
                    const SizedBox(height: 8),
                    // Subtitle Off Option
                    InkWell(
                      onTap: () {
                        _mkPlayer!.setSubtitleTrack(-1);
                        setSheetState(() {});
                        setState(() {});
                      },
                      borderRadius: BorderRadius.circular(10),
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 6),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        decoration: BoxDecoration(
                          color: (_mkPlayer!.state.currentSubtitleTrack == -1)
                              ? const Color(0xFF00F2FE).withOpacity(0.15)
                              : Colors.white.withOpacity(0.04),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: (_mkPlayer!.state.currentSubtitleTrack == -1)
                                ? const Color(0xFF00F2FE)
                                : Colors.transparent,
                            width: 1,
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              (_mkPlayer!.state.currentSubtitleTrack == -1)
                                  ? Icons.check_circle_rounded
                                  : Icons.radio_button_unchecked,
                              color: (_mkPlayer!.state.currentSubtitleTrack == -1)
                                  ? const Color(0xFF00F2FE)
                                  : Colors.white38,
                              size: 18,
                            ),
                            const SizedBox(width: 12),
                            Text(
                              _locale == 'ru' ? 'Выключены' : 'Off',
                              style: TextStyle(
                                color: (_mkPlayer!.state.currentSubtitleTrack == -1)
                                    ? Colors.white
                                    : Colors.white70,
                                fontWeight: (_mkPlayer!.state.currentSubtitleTrack == -1)
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    ...subtitleTracks.map((track) {
                      final isSelected = track.id == _mkPlayer!.state.currentSubtitleTrack;
                      return InkWell(
                        onTap: () {
                          _mkPlayer!.setSubtitleTrack(track.id, nativeIndex: track.nativeIndex);
                          setSheetState(() {});
                          setState(() {});
                        },
                        borderRadius: BorderRadius.circular(10),
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 6),
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          decoration: BoxDecoration(
                            color: isSelected ? const Color(0xFF00F2FE).withOpacity(0.15) : Colors.white.withOpacity(0.04),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: isSelected ? const Color(0xFF00F2FE) : Colors.transparent,
                              width: 1,
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                isSelected ? Icons.check_circle_rounded : Icons.radio_button_unchecked,
                                color: isSelected ? const Color(0xFF00F2FE) : Colors.white38,
                                size: 18,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  track.name,
                                  style: TextStyle(
                                    color: isSelected ? Colors.white : Colors.white70,
                                    fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }),
                    const SizedBox(height: 12),
                    // Button to load custom .srt or .vtt file
                    OutlinedButton.icon(
                      onPressed: () async {
                        try {
                          final pickedFile = await FilePicker.pickFile(
                            type: FileType.custom,
                            allowedExtensions: ['srt', 'vtt'],
                          );
                          if (pickedFile != null && pickedFile.path != null) {
                            final file = File(pickedFile.path!);
                            final content = await file.readAsString();
                            await _mkPlayer!.loadCustomSubtitlesContent(content, label: pickedFile.name);
                            if (mounted) {
                              Navigator.of(ctx).pop();
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(_locale == 'ru'
                                      ? 'Субтитры подключены: ${pickedFile.name}'
                                      : 'Subtitles loaded: ${pickedFile.name}'),
                                  backgroundColor: const Color(0xFF00F2FE),
                                ),
                              );
                            }
                          }
                        } catch (e) {
                          debugPrint('Error picking subtitle file: $e');
                        }
                      },
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF00F2FE),
                        side: const BorderSide(color: Color(0xFF00F2FE)),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      ),
                      icon: const Icon(Icons.file_upload_outlined, size: 18),
                      label: Text(
                        _locale == 'ru' ? '+ Загрузить файл субтитров (.srt / .vtt)' : '+ Upload Subtitles (.srt / .vtt)',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  // -------------------------------------------------------------
  // Picture-in-Picture (PiP) on Windows
  // -------------------------------------------------------------
  Future<void> _togglePipMode() async {
    if (!Platform.isWindows) return;
    try {
      if (!_isPipMode) {
        final bounds = await windowManager.getBounds();
        _beforePipBounds = bounds;
        await windowManager.setMinimumSize(const Size(320, 180));
        await windowManager.setSize(const Size(460, 270));
        await windowManager.setAlwaysOnTop(true);
        setState(() {
          _isPipMode = true;
          _showControls = false;
        });
      } else {
        await windowManager.setAlwaysOnTop(false);
        await windowManager.setMinimumSize(const Size(800, 600));
        if (_beforePipBounds != null) {
          await windowManager.setBounds(_beforePipBounds!);
        } else {
          await windowManager.setSize(const Size(1200, 720));
        }
        setState(() {
          _isPipMode = false;
          _showControls = true;
        });
      }
    } catch (e) {
      debugPrint('PiP toggle error: $e');
    }
  }

  // -------------------------------------------------------------
  // Desktop Drag & Drop Handler
  // -------------------------------------------------------------
  void _handleDroppedData(DropDoneDetails details) async {
    setState(() => _isDraggingOver = false);
    if (details.files.isEmpty) return;

    final first = details.files.first;
    final path = first.path;
    final name = first.name.toLowerCase();

    // 1. If dropped subtitle file (.srt / .vtt)
    if (name.endsWith('.srt') || name.endsWith('.vtt')) {
      try {
        final content = await File(path).readAsString();
        await _mkPlayer?.loadCustomSubtitlesContent(content, label: first.name);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(_locale == 'ru' ? 'Субтитры подключены: ${first.name}' : 'Subtitles loaded: ${first.name}'),
              backgroundColor: const Color(0xFF00F2FE),
            ),
          );
        }
      } catch (e) {
        debugPrint('Failed to load dropped subtitles: $e');
      }
      return;
    }

    // 2. If dropped video file (.mp4, .mkv, .webm, .avi, etc.)
    final isVideo = name.endsWith('.mp4') ||
        name.endsWith('.mkv') ||
        name.endsWith('.webm') ||
        name.endsWith('.avi') ||
        name.endsWith('.mov') ||
        name.endsWith('.flv') ||
        name.endsWith('.ts');

    if (isVideo) {
      if (!_isHost) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(_locale == 'ru'
                  ? 'Только хост может загружать видеофайлы'
                  : 'Only host can load video files'),
              backgroundColor: Colors.redAccent,
            ),
          );
        }
        return;
      }
      _changeVideo(path, first.name);
    }
  }

  Widget _buildDropTargetOverlay() {
    return Container(
      color: const Color(0xFF071215).withOpacity(0.85),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 20),
          decoration: BoxDecoration(
            color: const Color(0xFF161426),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFF00F2FE), width: 2),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF00F2FE).withOpacity(0.3),
                blurRadius: 20,
                spreadRadius: 2,
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.file_download_rounded, color: Color(0xFF00F2FE), size: 48),
              const SizedBox(height: 12),
              Text(
                _locale == 'ru'
                    ? 'Отпустите видео или файл субтитров'
                    : 'Drop video or subtitle file here',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                _locale == 'ru'
                    ? 'Поддерживаются .mp4, .mkv, .webm, .srt, .vtt'
                    : 'Supports .mp4, .mkv, .webm, .srt, .vtt',
                style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  bool _isLocalStreamHost = false;
  bool _hostAudioMuted = true;

  void _stopStreamBroadcast() {
    _socket.emit('stop-stream', {'roomId': widget.roomId});
    try { _localHttpServer?.close(force: true); } catch (_) {}
    _localHttpServer = null;
    _webrtcManager?.clearRemoteStream();
    if (mounted) {
      setState(() {
        _isLiveStreaming = false;
        _isLocalStreamHost = false;
        _hostAudioMuted = true;
      });
    }
  }

  Future<void> _startBrowserBroadcast() async {
    _isLocalStreamHost = true;
    _hostAudioMuted = true;
    _webrtcManager?.setAudioMuted(true);
    _webrtcManager?.clearRemoteStream();
    if (mounted) {
      setState(() {
        _isLiveStreaming = true;
      });
    }
    try {
      try { await _localHttpServer?.close(force: true); } catch (_) {}
      _localHttpServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final port = _localHttpServer!.port;
      final pageKey = base64UrlEncode(List<int>.generate(32, (_) => Random.secure().nextInt(256)));
      final rawServerUrl = widget.serverUrl.isEmpty ? 'http://127.0.0.1:3000' : widget.serverUrl;
      final serverUrl = rawServerUrl
          .replaceAll('wss://', 'https://')
          .replaceAll('ws://', 'http://')
          .replaceAll(RegExp(r'/$'), '');
      String socketIoJsContent = '';
      try {
        final res = await http.get(Uri.parse('$serverUrl/socket.io/socket.io.js')).timeout(const Duration(seconds: 4));
        if (res.statusCode == 200 && res.body.isNotEmpty) {
          socketIoJsContent = res.body;
        }
      } catch (_) {}

      final html = '''
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>Luna - Трансляция</title>
  <script src="$serverUrl/socket.io/socket.io.js"></script>
  <script>
    if (typeof io === 'undefined') {
      document.write('<script src="/socket.io.js?key=$pageKey"><\\/script>');
    }
  </script>
  <script>
    if (typeof io === 'undefined') {
      document.write('<script src="https://cdn.socket.io/4.7.5/socket.io.min.js"><\\/script>');
    }
  </script>
  <style>
    body { background-color: #161426; color: white; display: flex; flex-direction: column; align-items: center; justify-content: center; height: 100vh; margin: 0; font-family: sans-serif; text-align: center; }
    h2 { color: #00F2FE; }
    .warning { background-color: #ff4444; padding: 15px; border-radius: 8px; font-weight: bold; margin: 15px 0; max-width: 600px; }
    button { background: linear-gradient(90deg, #00F2FE 0%, #4FACFE 100%); color: #161426; font-weight: bold; border: none; padding: 15px 30px; font-size: 18px; border-radius: 30px; cursor: pointer; transition: transform 0.2s; }
    button:hover { transform: scale(1.05); }
    video { max-width: 320px; border: 2px solid #00F2FE; border-radius: 8px; margin-top: 20px; }
  </style>
</head>
<body>
  <h2>Трансляция вкладки для Luna</h2>

  <div class="warning">
    🛑 ВНИМАНИЕ: Откройте фильм в соседней вкладке ЗАРАНЕЕ.<br><br>
    После нажатия на кнопку ниже появится окно выбора. Обязательно выберите вкладку, на которой открыт фильм (а НЕ эту вкладку).
  </div>

  <p>Выберите <b>Вкладка Chrome / Edge</b> и поставьте галочку <b>Также поделиться аудио вкладки</b>!</p>

  <div style="margin: 15px 0; display: flex; align-items: center; justify-content: center; gap: 10px;">
    <label for="qualitySelect" style="font-size: 14px; color: #ccc;">Качество видео:</label>
    <select id="qualitySelect" style="background: #25223c; color: white; border: 1px solid #00F2FE; border-radius: 8px; padding: 6px 14px; font-size: 14px; cursor: pointer;">
      <option value="1080p" selected>1080p Full HD (30 FPS, 5.0 Mbps) - Чёткое</option>
      <option value="720p">720p HD (30 FPS, 2.5 Mbps) - Экономичное</option>
      <option value="1080p60">1080p 60 FPS (60 FPS, 7.5 Mbps) - Максимальная плавность</option>
      <option value="original">Оригинал экрана (до 10 Mbps)</option>
    </select>
  </div>

  <button id="startBtn">Выбрать вкладку и начать</button>
  <div id="status" style="margin-top: 15px; font-size: 16px;">Подключение к серверу...</div>
  <video id="preview" autoplay muted volume="0" style="display:none;"></video>

  <script>
    if (typeof io === 'undefined') {
      document.getElementById('status').innerHTML = '<span style="color:#ff4444;font-weight:bold;">Ошибка: Socket.IO библиотека не загрузилась.<br>Проверьте соединение с сервером или обновите страницу.</span>';
    } else {
      const socket = io(${jsonEncode(serverUrl)}, {
        extraHeaders: { 'bypass-tunnel-reminder': 'true' },
        query: { 'bypass-tunnel-reminder': 'true' },
        transports: ['websocket']
      });

      const roomId = ${jsonEncode(widget.roomId)};
      const password = ${jsonEncode(widget.password ?? '')};
      const username = ${jsonEncode('${widget.username}\u200B')};
      const clientId = ${jsonEncode(widget.clientId)};
      const hostToken = ${jsonEncode(_hostToken ?? globalHostTokens[widget.roomId] ?? '')};
      let localStream;
      let peerConnections = {};
      let latestUsers = [];
      const offerLocks = {};
      let selectedBitrate = 5000000;
      let selectedFps = 30;

      let config = {
        iceServers: [
          { urls: 'stun:stun.l.google.com:19302' },
          { urls: 'stun:stun1.l.google.com:19302' },
          { urls: 'stun:195.133.26.226:3478' }
        ]
      };

      socket.on('ice-servers', (servers) => {
        if (Array.isArray(servers) && servers.length > 0) {
          config.iceServers = servers;
        }
      });
      socket.emit('get-ice-servers', { roomId });

      let iceCandidateQueue = {};
      let hasRemoteDescription = {};

      socket.on('connect', () => {
        document.getElementById('status').innerText = 'Подключено к серверу! Нажмите кнопку выше, чтобы выбрать вкладку.';
        socket.emit('join-room', { roomId, username, password, clientId, hostToken, isBroadcaster: true });
        socket.emit('get-ice-servers', { roomId });
      });

      socket.on('connect_error', (err) => {
        document.getElementById('status').innerText = 'Ошибка подключения к серверу: ' + (err.message || err);
      });

      socket.on('room-error', (err) => {
        const msg = (err && err.message) ? err.message : JSON.stringify(err);
        document.getElementById('status').innerHTML = '<span style="color:#ff4444;font-weight:bold;">Ошибка комнаты: ' + msg + '</span>';
      });

      socket.on('action-error', (err) => {
        const msg = (err && err.message) ? err.message : JSON.stringify(err);
        document.getElementById('status').innerHTML = '<span style="color:#ffaa00;font-weight:bold;">Внимание: ' + msg + '</span>';
      });

      document.getElementById('startBtn').onclick = async () => {
        try {
          const qual = document.getElementById('qualitySelect') ? document.getElementById('qualitySelect').value : '1080p';
          let videoConstraints = {
            displaySurface: "browser",
            frameRate: { ideal: 30, max: 60 },
            width: { ideal: 1920, max: 1920 },
            height: { ideal: 1080, max: 1080 }
          };
          selectedBitrate = 5000000;
          selectedFps = 30;

          if (qual === '720p') {
            videoConstraints.width = { ideal: 1280, max: 1280 };
            videoConstraints.height = { ideal: 720, max: 720 };
            selectedBitrate = 2500000;
            selectedFps = 30;
          } else if (qual === '1080p60') {
            videoConstraints.frameRate = { ideal: 60, max: 60 };
            selectedBitrate = 7500000;
            selectedFps = 60;
          } else if (qual === 'original') {
            delete videoConstraints.width;
            delete videoConstraints.height;
            videoConstraints.frameRate = { ideal: 60, max: 60 };
            selectedBitrate = 10000000;
            selectedFps = 60;
          }

          localStream = await navigator.mediaDevices.getDisplayMedia({
            video: videoConstraints,
            audio: {
              echoCancellation: false,
              noiseSuppression: false,
              autoGainControl: false,
              suppressLocalAudioPlayback: false
            },
            systemAudio: "include"
          });

          // Mark video track as motion to prevent Chrome from queueing frames and causing massive latency
          localStream.getVideoTracks().forEach(track => {
            if ('contentHint' in track) {
              track.contentHint = 'motion';
            }
          });

          const prevEl = document.getElementById('preview');
          prevEl.srcObject = localStream;
          prevEl.muted = true;
          prevEl.volume = 0;
          prevEl.style.display = 'block';
          try { await prevEl.play(); } catch (_) {}

          const hasAudio = localStream.getAudioTracks().length > 0;
          if (hasAudio) {
            document.getElementById('status').innerHTML = '<span style="color:#00FF66;font-weight:bold;font-size:18px;">✅ ТРАНСЛЯЦИЯ АКТИВНА (Видео + Звук)!</span><br><p style="color:#aaa;margin-top:8px;">Звук и видео успешно передаются с минимальной задержкой. Теперь вы можете свернуть это окно браузера.</p>';
          } else {
            document.getElementById('status').innerHTML = '<div style="background:#4a2200;border:2px solid #ffaa00;padding:16px;border-radius:10px;margin:15px 0;text-align:left;"><span style="color:#ffaa00;font-size:18px;font-weight:bold;">⚠️ ВНИМАНИЕ: ЗВУК НЕ ЗАХВАЧЕН!</span><br><br>При выборе вкладки не была включена передача звука.<br>Зрители будут видеть картинку, но без звука.<br><br><b>Как включить звук:</b><br>1. Нажмите «Остановить трансляцию» в приложении Luna.<br>2. Начните заново и в окне выбора вкладки обязательно включите галочку <b>«Также предоставить доступ к аудио вкладки»</b> («Also share tab audio»).</div>';
          }
          document.getElementById('startBtn').style.display = 'none';

          localStream.getVideoTracks()[0].onended = () => {
            socket.emit('stop-stream', { roomId });
            document.getElementById('status').innerText = 'Трансляция завершена.';
          };

          socket.emit('start-stream', { roomId });

          // Proactively initiate WebRTC offer to all existing viewers in the room
          if (latestUsers && latestUsers.length > 0) {
            for (const user of latestUsers) {
              const uId = user.id || user;
              if (uId && uId !== socket.id && !peerConnections[uId]) {
                createOffer(uId);
              }
            }
          }

        } catch (err) {
          document.getElementById('status').innerText = 'Ошибка выбора вкладки: ' + (err.message || err);
        }
      };

      socket.on('new-viewer', async (data) => {
        if (!localStream) return;
        const vId = (data && data.viewerId) ? data.viewerId : data;
        if (vId && vId !== socket.id) {
          await createOffer(vId);
        }
      });

      socket.on('room-users', async (users) => {
        latestUsers = users || [];
        if (!localStream) return;
        for (const user of latestUsers) {
          const uId = user.id || user;
          if (uId && uId !== socket.id && !peerConnections[uId]) {
            await createOffer(uId);
          }
        }
      });

      socket.on('user-left', (data) => {
        const leftId = data ? (data.id || data) : null;
        if (leftId && peerConnections[leftId]) {
          try { peerConnections[leftId].close(); } catch(_) {}
          delete peerConnections[leftId];
        }
      });

      async function createOffer(targetId) {
        if (!localStream || !targetId || targetId === socket.id) return;
        if (offerLocks[targetId]) return;
        offerLocks[targetId] = true;

        try {
          const existingPc = peerConnections[targetId];
          if (existingPc && (existingPc.connectionState === 'connected' || existingPc.iceConnectionState === 'connected')) {
            offerLocks[targetId] = false;
            return;
          }
          if (existingPc) {
            try { existingPc.close(); } catch(_) {}
            delete peerConnections[targetId];
          }
          const pc = new RTCPeerConnection(config);
          peerConnections[targetId] = pc;

          localStream.getTracks().forEach(track => {
            if (track.kind === 'video' && 'contentHint' in track) {
              track.contentHint = 'motion';
            }
            pc.addTrack(track, localStream);
          });

          // Prefer H264 hardware acceleration on mobile and Windows
          try {
            const transceivers = pc.getTransceivers();
            for (const t of transceivers) {
              if (t.sender && t.sender.track && t.sender.track.kind === 'video') {
                if (window.RTCRtpReceiver && RTCRtpReceiver.getCapabilities) {
                  const caps = RTCRtpReceiver.getCapabilities('video');
                  if (caps && caps.codecs) {
                    const h264 = caps.codecs.filter(c => c.mimeType.toLowerCase() === 'video/h264');
                    const others = caps.codecs.filter(c => c.mimeType.toLowerCase() !== 'video/h264');
                    if (h264.length > 0) {
                      t.setCodecPreferences([...h264, ...others]);
                    }
                  }
                }
              }
            }
          } catch(e) {
            console.warn('Codec preference warning:', e);
          }

          pc.onicecandidate = (event) => {
            if (event.candidate) {
              const candObj = event.candidate.toJSON ? event.candidate.toJSON() : {
                candidate: event.candidate.candidate,
                sdpMid: event.candidate.sdpMid,
                sdpMLineIndex: event.candidate.sdpMLineIndex
              };
              socket.emit('webrtc-ice-candidate', {
                targetId,
                candidate: candObj,
                roomId
              });
            }
          };

          pc.onconnectionstatechange = () => {
            if (pc.connectionState === 'failed') {
              try { pc.close(); } catch(_) {}
              delete peerConnections[targetId];
            }
          };

          const offer = await pc.createOffer();
          await pc.setLocalDescription(offer);

          // Apply bitrate and framerate settings according to selected profile
          try {
            const senders = pc.getSenders();
            for (const s of senders) {
              if (s.track && s.track.kind === 'video' && s.getParameters && s.setParameters) {
                const params = s.getParameters();
                params.degradationPreference = 'maintain-framerate';
                if (!params.encodings || params.encodings.length === 0) {
                  params.encodings = [{}];
                }
                params.encodings[0].maxBitrate = selectedBitrate;
                params.encodings[0].maxFramerate = selectedFps;
                await s.setParameters(params);
              }
            }
          } catch(e) {
            console.warn('Bitrate param warning:', e);
          }

          socket.emit('webrtc-offer', {
            targetId,
            offer: { type: offer.type, sdp: offer.sdp },
            roomId
          });
        } catch (err) {
          console.error('Error creating offer for ' + targetId, err);
        } finally {
          setTimeout(() => { offerLocks[targetId] = false; }, 1500);
        }
      }

      socket.on('webrtc-answer', async (data) => {
        if (data && data.senderId && peerConnections[data.senderId] && data.answer) {
          const pc = peerConnections[data.senderId];
          try {
            await pc.setRemoteDescription(new RTCSessionDescription(data.answer));
            hasRemoteDescription[data.senderId] = true;
            if (iceCandidateQueue[data.senderId]) {
              for (const candidate of iceCandidateQueue[data.senderId]) {
                if (candidate) {
                  try { await pc.addIceCandidate(new RTCIceCandidate(candidate)); } catch(_) {}
                }
              }
              delete iceCandidateQueue[data.senderId];
            }
          } catch(e) {
            console.error('Error setting remote answer:', e);
          }
        }
      });

      socket.on('webrtc-ice-candidate', async (data) => {
        if (data && data.senderId && peerConnections[data.senderId] && data.candidate) {
          const pc = peerConnections[data.senderId];
          if (hasRemoteDescription[data.senderId]) {
            try { await pc.addIceCandidate(new RTCIceCandidate(data.candidate)); } catch(_) {}
          } else {
            if (!iceCandidateQueue[data.senderId]) iceCandidateQueue[data.senderId] = [];
            iceCandidateQueue[data.senderId].push(data.candidate);
          }
        }
      });

      socket.on('stream-stopped', () => {
        document.body.innerHTML = '<h2>Трансляция завершена</h2><p>Можете закрыть эту вкладку.</p>';
        window.close();
      });
    }
  </script>
</body>
</html>
      ''';

      _localHttpServer?.listen((HttpRequest request) async {
        if (request.uri.queryParameters['key'] != pageKey) {
          request.response.statusCode = HttpStatus.forbidden;
          await request.response.close();
          return;
        }
        request.response.headers.set('Referrer-Policy', 'no-referrer');
        request.response.headers.set('Cache-Control', 'no-store');
        if (request.uri.path == '/socket.io.js') {
          if (socketIoJsContent.isEmpty) {
            try {
              final res = await http.get(Uri.parse('$serverUrl/socket.io/socket.io.js')).timeout(const Duration(seconds: 4));
              if (res.statusCode == 200 && res.body.isNotEmpty) {
                socketIoJsContent = res.body;
              }
            } catch (_) {}
          }
          request.response.headers.contentType = ContentType('application', 'javascript', charset: 'utf-8');
          request.response.write(socketIoJsContent);
          await request.response.close();
        } else if (request.uri.path == '/' || request.uri.path == '/index.html') {
          request.response.headers.contentType = ContentType.html;
          request.response.write(html);
          await request.response.close();
        } else {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
        }
      });

      final url = Uri.parse('http://127.0.0.1:$port/?key=$pageKey');
      if (await canLaunchUrl(url)) {
        await launchUrl(url, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      debugPrint("Error starting browser broadcast: $e");
    }
  }

  Widget _buildHostWaitingBanner() {
    return Container(
      color: const Color(0xFF100E1D),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: const Color(0xFF6C63FF).withOpacity(0.15),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.open_in_browser,
                size: 56,
                color: Color(0xFF00F2FE),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              _locale == 'ru' ? 'Ожидание выбора вкладки...' : 'Waiting for tab selection...',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                _locale == 'ru'
                    ? 'В открывшемся браузере выберите вкладку с фильмом и нажмите «Поделиться».\nВаш стрим появится здесь сразу после выбора!'
                    : 'In the opened browser window, choose your video tab and click "Share".\nYour stream will appear here immediately after!',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.7),
                  fontSize: 13,
                  height: 1.4,
                ),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _stopStreamBroadcast,
              icon: const Icon(Icons.close, size: 18),
              label: Text(
                _locale == 'ru' ? 'Отмена трансляции' : 'Cancel stream',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.redAccent,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(30),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
  void _triggerControlsVisibility() {
    setState(() {
      _showControls = true;
    });
    _controlsTimer?.cancel();
    _controlsTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && ((_mkPlayer?.state.playing ?? false) || _isLiveStreaming)) {
        setState(() {
          _showControls = false;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_isPipMode) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            if (_playerReady && _mkPlayer != null && _mkPlayer!.controller.value.isInitialized)
              Offstage(
                offstage: _isLiveStreaming,
                child: Webview(_mkPlayer!.controller),
              ),
            MouseRegion(
              onEnter: (_) => setState(() => _showControls = true),
              onExit: (_) => setState(() => _showControls = false),
              child: AnimatedOpacity(
                opacity: _showControls ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 200),
                child: Container(
                  color: Colors.black54,
                  child: Stack(
                    children: [
                      Align(
                        alignment: Alignment.topRight,
                        child: Padding(
                          padding: const EdgeInsets.all(8.0),
                          child: IconButton(
                            icon: const Icon(Icons.open_in_new_rounded, color: Color(0xFF00F2FE)),
                            tooltip: _locale == 'ru' ? 'Выйти из PiP' : 'Exit PiP',
                            onPressed: _togglePipMode,
                          ),
                        ),
                      ),
                      Center(
                        child: IconButton(
                          iconSize: 44,
                          color: Colors.white,
                          icon: Icon(_mkPlayer?.state.playing == true ? Icons.pause_circle_filled : Icons.play_circle_filled),
                          onPressed: () {
                            if (_mkPlayer?.state.playing == true) {
                              _localPause();
                            } else {
                              _localPlay();
                            }
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    if (!_hasJoinedRoom) {
      return const Scaffold(
        backgroundColor: Color(0xFF161426),
        body: Center(
          child: CircularProgressIndicator(color: Color(0xFF00F2FE)),
        ),
      );
    }

    final screenWidth = MediaQuery.of(context).size.width;
    final isDesktop = screenWidth > 800;

    return Scaffold(
      appBar: AppBar(
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
                globalAppVersion,
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
      ),
      body: Container(
        color: const Color(0xFF0D0B14),
        child: isDesktop
            ? Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: _buildMainContent(),
                  ),
                  if (_isSidebarVisible) ...[
                    VerticalDivider(
                      color: Colors.white.withOpacity(0.05),
                      width: 1,
                    ),
                    Container(
                      width: 340, // Increased sidebar width
                      color: const Color(0xFF100E1C),
                      child: _buildControlSidebar(),
                    ),
                  ],
                ],
              )
            : Column(
                children: [
                  Expanded(
                    child: _buildMainContent(),
                  ),
                  if (_isSidebarVisible)
                    _buildControlSidebarCollapsed(),
                ],
              ),
      ),
    );
  }

  Widget _buildMainContent() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Video display container with Drag & Drop support
        Expanded(
          child: DropTarget(
            onDragEntered: (_) => setState(() => _isDraggingOver = true),
            onDragExited: (_) => setState(() => _isDraggingOver = false),
            onDragDone: (details) => _handleDroppedData(details),
            child: Container(
              color: Colors.black,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  MouseRegion(
                    onHover: (_) => _triggerControlsVisibility(),
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _triggerControlsVisibility,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          // Background audio/video player (always mounted so live audio stream plays for viewers)
                          if (_playerReady && _mkPlayer != null && _mkPlayer!.controller.value.isInitialized)
                            Offstage(
                              offstage: _isLiveStreaming,
                              child: Webview(_mkPlayer!.controller),
                            )
                          else
                            const Center(
                              child: CircularProgressIndicator(
                                valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF6C63FF)),
                              ),
                            ),

                          // Live video stream overlay (WebRTC)
                          if (_isLiveStreaming) ...[
                            if (_webrtcManager != null &&
                                _webrtcManager!.remoteRenderer.srcObject != null)
                              RTCVideoView(
                                _webrtcManager!.remoteRenderer,
                                objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
                              )
                            else if (_isLocalStreamHost)
                              _buildHostWaitingBanner()
                            else
                              Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const CircularProgressIndicator(
                                      valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF00F2FE)),
                                    ),
                                    const SizedBox(height: 16),
                                    Text(
                                      _locale == 'ru' ? 'Подключение к трансляции...' : 'Connecting to stream...',
                                      style: const TextStyle(color: Colors.white70, fontSize: 14),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                          AnimatedOpacity(
                            opacity: _showControls ? 1.0 : 0.0,
                            duration: const Duration(milliseconds: 300),
                            child: _buildVideoControlsOverlay(),
                          ),
                          // Show placeholder when no video is loaded
                          if (_currentVideoUrl.isEmpty && !_isLiveStreaming)
                            _buildEmptyState(),
                        ],
                      ),
                    ),
                  ),
                  if (_isDraggingOver)
                    _buildDropTargetOverlay(),
                ],
              ),
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
            if (Platform.isWindows && _isHost) ...[
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: _startBrowserBroadcast,
                icon: const Icon(Icons.tab, size: 20),
                label: Text(
                  _locale == 'ru' ? 'Запустить трансляцию вкладки' : 'Start Tab Broadcast',
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF6C63FF),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildVideoControlsOverlay() {
    if (_mkPlayer == null) return const SizedBox.shrink();

    final isMeHost = _isHost;

    final position = _mkPlayer!.state.position;
    final duration = _mkPlayer!.state.duration;
    final isPlaying = _mkPlayer!.state.playing;
    final volume = _mkPlayer!.state.volume / 100.0; // media_kit volume is 0-100

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
                  child: (_isLiveStreaming || _currentVideoName == 'No Video Loaded' || _currentVideoUrl.isEmpty)
                      ? (_isLiveStreaming
                          ? Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                                  decoration: BoxDecoration(
                                    color: const Color(0x33E53935),
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(color: const Color(0xFFEF5350), width: 1.5),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(Icons.circle, color: Color(0xFFEF5350), size: 10),
                                      const SizedBox(width: 6),
                                      Text(
                                        _isLocalStreamHost
                                            ? (_locale == 'ru' ? 'ВАШ СТРИМ (В ЭФИРЕ)' : 'YOUR STREAM (LIVE)')
                                            : (_locale == 'ru' ? 'ТРАНСЛЯЦИЯ ХОСТА' : 'HOST STREAM'),
                                        style: const TextStyle(
                                          color: Color(0xFFEF5350),
                                          fontSize: 12,
                                          fontWeight: FontWeight.bold,
                                          letterSpacing: 0.5,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                if (_isLocalStreamHost) ...[
                                  const SizedBox(width: 8),
                                  InkWell(
                                    onTap: () {
                                      setState(() {
                                        _hostAudioMuted = !_hostAudioMuted;
                                        _webrtcManager?.setAudioMuted(_hostAudioMuted);
                                      });
                                    },
                                    borderRadius: BorderRadius.circular(8),
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                                      decoration: BoxDecoration(
                                        color: Colors.black54,
                                        borderRadius: BorderRadius.circular(8),
                                        border: Border.all(
                                          color: _hostAudioMuted ? Colors.amber.withOpacity(0.5) : Colors.green.withOpacity(0.5),
                                        ),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            _hostAudioMuted ? Icons.volume_off : Icons.volume_up,
                                            color: _hostAudioMuted ? Colors.amberAccent : Colors.greenAccent,
                                            size: 14,
                                          ),
                                          const SizedBox(width: 4),
                                          Text(
                                            _hostAudioMuted
                                                ? (_locale == 'ru' ? 'Звук в плеере: выкл' : 'App sound: off')
                                                : (_locale == 'ru' ? 'Звук в плеере: вкл' : 'App sound: on'),
                                            style: const TextStyle(color: Colors.white, fontSize: 11),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            )
                          : const SizedBox.shrink())
                      : Text(
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
                if (_isLiveStreaming && _isLocalStreamHost)
                  Padding(
                    padding: const EdgeInsets.only(right: 8.0),
                    child: ElevatedButton.icon(
                      onPressed: _stopStreamBroadcast,
                      icon: const Icon(Icons.stop_screen_share, size: 16),
                      label: Text(
                        _locale == 'ru' ? 'Остановить' : 'Stop',
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.redAccent,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        minimumSize: Size.zero,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
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
                  // Progress Slider / LIVE badge
                  if (!_isLiveStreaming)
                    Row(
                      children: [
                        Text(
                          formatDuration(position),
                          style: const TextStyle(color: Colors.white, fontSize: 12),
                        ),
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
                        Text(
                          formatDuration(duration),
                          style: const TextStyle(color: Colors.white, fontSize: 12),
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
                            if (_isLiveStreaming) ...[
                              if (_isLocalStreamHost)
                                Padding(
                                  padding: const EdgeInsets.only(right: 12),
                                  child: ElevatedButton.icon(
                                    onPressed: _stopStreamBroadcast,
                                    icon: const Icon(Icons.stop_screen_share, size: 16),
                                    label: Text(
                                      _locale == 'ru' ? 'Остановить стрим' : 'Stop Stream',
                                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                                    ),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: Colors.redAccent,
                                      foregroundColor: Colors.white,
                                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                                    ),
                                  ),
                                ),
                            ] else if (isMeHost) ...[
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
                                onPressed: _skipVideo,
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
                          const SizedBox(width: 4),
                          // Subtitles and Audio tracks button
                          IconButton(
                            tooltip: _locale == 'ru' ? 'Субтитры и аудиодорожки' : 'Subtitles & Audio Tracks',
                            icon: const Icon(Icons.subtitles_rounded),
                            color: (_mkPlayer?.state.currentSubtitleTrack != -1 || _mkPlayer?.state.currentAudioTrack != -1)
                                ? const Color(0xFF00F2FE)
                                : Colors.white70,
                            onPressed: _showTracksDialog,
                          ),
                          // Picture-in-Picture (PiP) toggle
                          if (Platform.isWindows)
                            IconButton(
                              tooltip: _locale == 'ru' ? 'Картинка в картинке' : 'Picture-in-Picture',
                              icon: Icon(_isPipMode ? Icons.picture_in_picture_alt : Icons.picture_in_picture_alt_outlined),
                              color: _isPipMode ? const Color(0xFF00F2FE) : Colors.white70,
                              onPressed: _togglePipMode,
                            ),
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
            child: IndexedStack(
              index: _selectedTab,
              children: [
                _buildControlsTab(),
                _buildChatTab(),
                _buildSettingsTab(),
              ],
            ),
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
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildControlsTab() {
    // Check if the current user is host
    final isMeHost = _isHost;

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
                    _locale == 'ru'
                        ? 'Только создатель комнаты может менять фильм, ставить на паузу или запускать трансляцию.'
                        : 'Only the room host can change videos, control playback, or start broadcasts.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: Colors.white.withOpacity(0.6)),
                  ),
                ],
              ),
            ),
            if (_queue.isNotEmpty) ...[
              const SizedBox(height: 16),
              _buildCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      _locale == 'ru' ? 'Очередь воспроизведения' : 'Playback Queue',
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
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
                            ],
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
            ],
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

          // Tab Streaming Button (Windows Host Only)
          if (Platform.isWindows && isMeHost) ...[
            _buildCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    _locale == 'ru' ? 'Трансляция из вкладки' : 'Stream Browser Tab',
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  if (_isLiveStreaming)
                    ElevatedButton.icon(
                      onPressed: _stopStreamBroadcast,
                      icon: const Icon(Icons.stop_screen_share, size: 18),
                      label: Text(
                        _locale == 'ru' ? 'Остановить трансляцию' : 'Stop Stream',
                        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.redAccent,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                    )
                  else
                    ElevatedButton.icon(
                      onPressed: _startBrowserBroadcast,
                      icon: const Icon(Icons.tab, size: 18),
                      label: Text(
                        _locale == 'ru' ? 'Запустить трансляцию из вкладки' : 'Start Tab Stream',
                        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF6C63FF),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 10),
          ],

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
                      ? 'Поддерживает VK, Rutube, YouTube, прямые ссылки и плееры (api.collaps.to, alloha.tv)'
                      : 'Supports VK, Rutube, YouTube, direct video files and embeds (api.collaps.to, alloha.tv)',
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
                    if (_currentVideoUrl.isNotEmpty || _isLiveStreaming) ...[
                      OutlinedButton.icon(
                        onPressed: _clearPlayer,
                        icon: const Icon(Icons.cleaning_services, size: 14, color: Colors.redAccent),
                        label: Text(
                          _locale == 'ru' ? 'Очистить плеер' : 'Clear Player',
                          style: const TextStyle(fontSize: 11, color: Colors.redAccent, fontWeight: FontWeight.bold),
                        ),
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: Colors.redAccent),
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
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
                final isHost = user['isHost'] == true || (_hostUsername != null && (user['username'] as String).toLowerCase() == _hostUsername!.toLowerCase()) || index == 0;

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
                          '${user['username']}${isMe ? (_locale == 'ru' ? ' (Вы)' : ' (You)') : ''}',
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

  String _formatSystemMessage(String rawText) {
    if (_locale == 'ru') {
      if (rawText.endsWith('joined the room')) {
        final name = rawText.replaceAll(' joined the room', '').trim();
        return '$name присоединился к комнате';
      }
      if (rawText.endsWith('left the room')) {
        final name = rawText.replaceAll(' left the room', '').trim();
        return '$name покинул комнату';
      }
      if (rawText.contains('kicked from the room') || rawText.contains('was kicked')) {
        final name = rawText.replaceAll(' was kicked from the room', '').replaceAll(' was kicked', '').trim();
        return '$name был исключен из комнаты';
      }
      if (rawText.contains('banned from the room') || rawText.contains('was banned')) {
        final name = rawText.replaceAll(' was banned from the room', '').replaceAll(' was banned', '').trim();
        return '$name был заблокирован в комнате';
      }
    } else {
      if (rawText.endsWith('присоединился к комнате')) {
        final name = rawText.replaceAll(' присоединился к комнате', '').trim();
        return '$name joined the room';
      }
      if (rawText.endsWith('покинул комнату')) {
        final name = rawText.replaceAll(' покинул комнату', '').trim();
        return '$name left the room';
      }
      if (rawText.contains('был исключен из комнаты')) {
        final name = rawText.replaceAll(' был исключен из комнаты', '').trim();
        return '$name was kicked from the room';
      }
      if (rawText.contains('был заблокирован в комнате')) {
        final name = rawText.replaceAll(' был заблокирован в комнате', '').trim();
        return '$name was banned from the room';
      }
    }
    return rawText;
  }

  String _formatMessageTime(String? rawTime) {
    if (rawTime == null || rawTime.isEmpty) {
      final now = DateTime.now();
      return '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    }
    final numVal = int.tryParse(rawTime);
    if (numVal != null && numVal > 1000000) {
      final dt = DateTime.fromMillisecondsSinceEpoch(numVal);
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    }
    if (rawTime.contains(':')) {
      final parts = rawTime.split(':');
      if (parts.length >= 2) {
        return '${parts[0].padLeft(2, '0')}:${parts[1].padLeft(2, '0')}';
      }
    }
    return rawTime;
  }

  Widget _buildSystemMessageWidget(String text) {
    final localized = _formatSystemMessage(text);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 16),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.06),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white.withOpacity(0.08)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                localized.contains('присоединился') || localized.contains('joined')
                    ? Icons.login_rounded
                    : (localized.contains('покинул') || localized.contains('left')
                        ? Icons.logout_rounded
                        : Icons.info_outline),
                size: 13,
                color: localized.contains('присоединился') || localized.contains('joined')
                    ? Colors.greenAccent.withOpacity(0.8)
                    : (localized.contains('покинул') || localized.contains('left')
                        ? Colors.orangeAccent.withOpacity(0.8)
                        : Colors.white.withOpacity(0.6)),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  localized,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.white.withOpacity(0.7),
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showMessageActions(Map<String, dynamic> msg, [Offset? position]) {
    try {
      HapticFeedback.lightImpact();
    } catch (_) {}

    final targetPos = position ?? _lastChatTapPosition;

    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'TG_ACTIONS',
      barrierColor: Colors.black.withOpacity(0.2),
      transitionDuration: const Duration(milliseconds: 140),
      pageBuilder: (ctx, anim1, anim2) => const SizedBox(),
      transitionBuilder: (ctx, anim, secondaryAnim, child) {
        final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
        final reactions = (msg['reactions'] is Map) ? (msg['reactions'] as Map) : {};
        final hasImage = msg['imageUrl'] != null && (msg['imageUrl'] as String).trim().isNotEmpty;
        final hasText = msg['text'] != null && (msg['text'] as String).trim().isNotEmpty;

        final screenSize = MediaQuery.of(ctx).size;
        final isSidebar = screenSize.width >= 700 && _isSidebarVisible;
        final sidebarLeft = isSidebar ? (screenSize.width - 340.0) : 0.0;

        const menuWidth = 296.0;
        int itemCount = 1;
        if (hasText) itemCount++;
        if (hasImage) itemCount += 2;
        final menuHeight = 44.0 + 8.0 + (itemCount * 42.0);

        double left;
        double top;

        if (targetPos != null) {
          if (isSidebar && targetPos.dx >= sidebarLeft - 20) {
            // Keep inside sidebar aligned nicely to the click
            if (targetPos.dx + menuWidth > screenSize.width - 10) {
              left = (screenSize.width - menuWidth - 10.0);
            } else {
              left = (targetPos.dx - 10).clamp(sidebarLeft + 6.0, screenSize.width - menuWidth - 10.0);
            }
          } else {
            // General desktop / popup positioning:
            if (targetPos.dx + menuWidth > screenSize.width - 16) {
              left = (targetPos.dx - menuWidth).clamp(16.0, screenSize.width - menuWidth - 16.0);
            } else {
              left = (targetPos.dx - 10).clamp(16.0, screenSize.width - menuWidth - 16.0);
            }
          }

          // Vertical placement:
          if (targetPos.dy + menuHeight <= screenSize.height - 24) {
            top = (targetPos.dy - 8).clamp(16.0, screenSize.height - menuHeight - 16.0);
          } else {
            top = (targetPos.dy - menuHeight + 8).clamp(16.0, screenSize.height - menuHeight - 16.0);
          }
        } else {
          left = (screenSize.width - menuWidth - 20).clamp(16.0, screenSize.width - 16.0);
          top = (screenSize.height / 2 - menuHeight / 2).clamp(16.0, screenSize.height - menuHeight - 16.0);
        }

        final alignRight = (left + menuWidth / 2) > (screenSize.width / 2);
        final opensUpward = targetPos != null && (targetPos.dy > top + (menuHeight / 2));

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => Navigator.of(ctx).pop(),
          onSecondaryTap: () => Navigator.of(ctx).pop(),
          child: Scaffold(
            backgroundColor: Colors.transparent,
            body: Stack(
              children: [
                Positioned(
                  left: left,
                  top: top,
                  child: ScaleTransition(
                    alignment: opensUpward
                        ? (alignRight ? Alignment.bottomRight : Alignment.bottomLeft)
                        : (alignRight ? Alignment.topRight : Alignment.topLeft),
                    scale: Tween<double>(begin: 0.9, end: 1.0).animate(curved),
                    child: FadeTransition(
                      opacity: anim,
                      child: GestureDetector(
                        onTap: () {}, // prevent close on click inside
                        child: Container(
                          constraints: const BoxConstraints(maxWidth: menuWidth),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: alignRight ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                            children: [
                              // 1. Telegram Floating Emoji Reactions Capsule with acrylic blur
                              ClipRRect(
                                borderRadius: BorderRadius.circular(26),
                                child: BackdropFilter(
                                  filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF1E2333).withOpacity(0.92),
                                      borderRadius: BorderRadius.circular(26),
                                      border: Border.all(
                                        color: Colors.white.withOpacity(0.14),
                                        width: 1,
                                      ),
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.black.withOpacity(0.45),
                                          blurRadius: 18,
                                          offset: const Offset(0, 6),
                                        ),
                                      ],
                                    ),
                                    child: SingleChildScrollView(
                                      scrollDirection: Axis.horizontal,
                                      physics: const BouncingScrollPhysics(),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: _quickEmojis.map((emoji) {
                                          final hasReacted = reactions[emoji] is List && (reactions[emoji] as List).contains(widget.username);
                                          return Padding(
                                            padding: const EdgeInsets.symmetric(horizontal: 1.5),
                                            child: Material(
                                              color: Colors.transparent,
                                              child: InkWell(
                                                onTap: () {
                                                  Navigator.of(ctx).pop();
                                                  _toggleReaction(msg['id'] ?? '', emoji);
                                                },
                                                borderRadius: BorderRadius.circular(18),
                                                splashColor: const Color(0xFF00F2FE).withOpacity(0.3),
                                                hoverColor: Colors.white.withOpacity(0.1),
                                                child: AnimatedContainer(
                                                  duration: const Duration(milliseconds: 140),
                                                  padding: const EdgeInsets.all(4.5),
                                                  decoration: BoxDecoration(
                                                    shape: BoxShape.circle,
                                                    color: hasReacted
                                                        ? const Color(0xFF00F2FE).withOpacity(0.25)
                                                        : Colors.transparent,
                                                    border: hasReacted
                                                        ? Border.all(color: const Color(0xFF00F2FE), width: 1.5)
                                                        : null,
                                                  ),
                                                  child: Text(
                                                    emoji,
                                                    style: const TextStyle(fontSize: 20),
                                                  ),
                                                ),
                                              ),
                                            ),
                                          );
                                        }).toList(),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 6),
                              // 2. Telegram Floating Actions Context Menu with acrylic blur
                              ClipRRect(
                                borderRadius: BorderRadius.circular(14),
                                child: BackdropFilter(
                                  filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                                  child: Container(
                                    width: 220,
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF1E2333).withOpacity(0.92),
                                      borderRadius: BorderRadius.circular(14),
                                      border: Border.all(
                                        color: Colors.white.withOpacity(0.14),
                                        width: 1,
                                      ),
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.black.withOpacity(0.4),
                                          blurRadius: 20,
                                          offset: const Offset(0, 8),
                                        ),
                                      ],
                                    ),
                                    clipBehavior: Clip.antiAlias,
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        // Reply action
                                        _buildTgMenuItem(
                                          icon: Icons.reply_rounded,
                                          iconColor: const Color(0xFF00F2FE),
                                          label: _locale == 'ru' ? 'Ответить' : 'Reply',
                                          onTap: () {
                                            Navigator.of(ctx).pop();
                                            _startReply(msg);
                                          },
                                        ),
                                        // Copy text action
                                        if (hasText) ...[
                                          _buildTgMenuDivider(),
                                          _buildTgMenuItem(
                                            icon: Icons.copy_rounded,
                                            iconColor: Colors.white70,
                                            label: _locale == 'ru' ? 'Копировать' : 'Copy text',
                                            onTap: () {
                                              Clipboard.setData(ClipboardData(text: msg['text'] as String));
                                              Navigator.of(ctx).pop();
                                              if (mounted) {
                                                ScaffoldMessenger.of(context).showSnackBar(
                                                  SnackBar(
                                                    content: Text(_locale == 'ru' ? 'Скопировано в буфер' : 'Copied to clipboard'),
                                                    duration: const Duration(seconds: 1),
                                                  ),
                                                );
                                              }
                                            },
                                          ),
                                        ],
                                        // Image-specific actions
                                        if (hasImage) ...[
                                          _buildTgMenuDivider(),
                                          _buildTgMenuItem(
                                            icon: Icons.fullscreen_rounded,
                                            iconColor: const Color(0xFF00F2FE),
                                            label: _locale == 'ru' ? 'Открыть фото' : 'Open photo',
                                            onTap: () {
                                              Navigator.of(ctx).pop();
                                              _showFullscreenImage(msg['imageUrl']);
                                            },
                                          ),
                                          _buildTgMenuDivider(),
                                          _buildTgMenuItem(
                                            icon: Icons.link_rounded,
                                            iconColor: Colors.white70,
                                            label: _locale == 'ru' ? 'Скопировать ссылку' : 'Copy link',
                                            onTap: () {
                                              Clipboard.setData(ClipboardData(text: msg['imageUrl'] as String));
                                              Navigator.of(ctx).pop();
                                              if (mounted) {
                                                ScaffoldMessenger.of(context).showSnackBar(
                                                  SnackBar(
                                                    content: Text(_locale == 'ru' ? 'Ссылка скопирована' : 'Link copied'),
                                                    duration: const Duration(seconds: 1),
                                                  ),
                                                );
                                              }
                                            },
                                          ),
                                        ],
                                      ],
                                    ),
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
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildTgMenuItem({
    required IconData icon,
    required Color iconColor,
    required String label,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        splashColor: const Color(0xFF00F2FE).withOpacity(0.15),
        hoverColor: Colors.white.withOpacity(0.06),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
          child: Row(
            children: [
              Icon(icon, size: 20, color: iconColor),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w500,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTgMenuDivider() {
    return Divider(
      height: 1,
      thickness: 1,
      color: Colors.white.withOpacity(0.06),
    );
  }

  Widget _buildChatTab() {
    final primaryColor = Theme.of(context).primaryColor;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyV, control: true): _handlePasteFromClipboard,
        const SingleActivator(LogicalKeyboardKey.keyV, meta: true): _handlePasteFromClipboard,
      },
      child: Focus(
        autofocus: false,
        child: Column(
          children: [
        // Message log
        Expanded(
          child: Stack(
            children: [
              Container(
                padding: EdgeInsets.symmetric(horizontal: 4, vertical: _compactChat ? 4 : 8),
                child: ListView.builder(
                  controller: _chatScrollController,
                  itemCount: _messages.length,
                  itemBuilder: (context, index) {
                    final msg = _messages[index];
                    final isSystem = msg['sender'] == 'System' || msg['sender'] == 'Система' || msg['clientId'] == 'system';
                    if (isSystem) {
                      if (!_showSystemMessages) return const SizedBox.shrink();
                      return _buildSystemMessageWidget(msg['text'] ?? '');
                    }

                    final isMe = msg['clientId'] == widget.clientId;
                    final senderInitial = (msg['sender'] != null && msg['sender']!.isNotEmpty)
                        ? msg['sender']!.substring(0, 1).toUpperCase()
                        : '?';
                    final imageUrl = msg['imageUrl']?.toString();
                    final hasImage = imageUrl != null && imageUrl.isNotEmpty;
                    final replyTo = (msg['replyTo'] is Map) ? Map<String, dynamic>.from(msg['replyTo']) : null;
                    final reactions = (msg['reactions'] is Map) ? Map<String, dynamic>.from(msg['reactions']) : <String, dynamic>{};

                    return Padding(
                      padding: EdgeInsets.symmetric(vertical: _compactChat ? 2 : 4),
                      child: Row(
                        mainAxisAlignment: isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          if (!isMe)
                            Padding(
                              padding: const EdgeInsets.only(right: 8, bottom: 2),
                              child: CircleAvatar(
                                radius: _compactChat ? 12 : 14,
                                backgroundColor: const Color(0xFF6C63FF).withOpacity(0.3),
                                child: Text(
                                  senderInitial,
                                  style: TextStyle(fontSize: _compactChat ? 9 : 10, color: const Color(0xFF00F2FE), fontWeight: FontWeight.bold),
                                ),
                              ),
                            ),
                          Flexible(
                            child: Column(
                              crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                              children: [
                                GestureDetector(
                                  onTapDown: (details) => _lastChatTapPosition = details.globalPosition,
                                  onSecondaryTapDown: (details) => _lastChatTapPosition = details.globalPosition,
                                  onTap: () => _showMessageActions(msg, _lastChatTapPosition),
                                  onSecondaryTap: () => _showMessageActions(msg, _lastChatTapPosition),
                                  onLongPressStart: (details) {
                                    _lastChatTapPosition = details.globalPosition;
                                    _showMessageActions(msg, details.globalPosition);
                                  },
                                  child: Container(
                                    padding: EdgeInsets.symmetric(
                                      horizontal: _compactChat ? 8 : 12,
                                      vertical: _compactChat ? 6 : 8,
                                    ),
                                    constraints: const BoxConstraints(maxWidth: 280),
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
                                        // Sender name (if not me) & action button
                                        Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            if (!isMe)
                                              Expanded(
                                                child: Text(
                                                  msg['sender'] ?? '',
                                                  style: const TextStyle(
                                                    fontSize: 11,
                                                    fontWeight: FontWeight.bold,
                                                    color: Color(0xFF00F2FE),
                                                  ),
                                                ),
                                              ),
                                            InkWell(
                                              onTapDown: (details) => _lastChatTapPosition = details.globalPosition,
                                              onTap: () => _showMessageActions(msg, _lastChatTapPosition),
                                              borderRadius: BorderRadius.circular(10),
                                              child: Tooltip(
                                                message: _locale == 'ru' ? 'Реакции и действия' : 'Reactions & actions',
                                                child: Padding(
                                                  padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
                                                  child: Icon(
                                                    Icons.add_reaction_outlined,
                                                    size: 14,
                                                    color: Colors.white.withOpacity(0.35),
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                        // Reply-to quote snippet
                                        if (replyTo != null) ...[
                                          const SizedBox(height: 3),
                                          Container(
                                            margin: const EdgeInsets.only(bottom: 6),
                                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                            decoration: BoxDecoration(
                                              color: Colors.black.withOpacity(0.2),
                                              borderRadius: BorderRadius.circular(6),
                                              border: const Border(
                                                left: BorderSide(color: Color(0xFF00F2FE), width: 3),
                                              ),
                                            ),
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  replyTo['sender'] ?? replyTo['username'] ?? '',
                                                  style: const TextStyle(
                                                    fontSize: 10,
                                                    fontWeight: FontWeight.bold,
                                                    color: Color(0xFF00F2FE),
                                                  ),
                                                ),
                                                Text(
                                                  replyTo['text'] ?? '',
                                                  maxLines: 1,
                                                  overflow: TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                    fontSize: 10,
                                                    color: Colors.white.withOpacity(0.7),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ],
                                        // Image or GIF preview
                                        if (hasImage) ...[
                                          const SizedBox(height: 4),
                                          GestureDetector(
                                            onTap: () => _showFullscreenImage(imageUrl),
                                            onSecondaryTapDown: (details) => _lastChatTapPosition = details.globalPosition,
                                            onSecondaryTap: () => _showMessageActions(msg, _lastChatTapPosition),
                                            child: ClipRRect(
                                              borderRadius: BorderRadius.circular(10),
                                              child: ConstrainedBox(
                                                constraints: const BoxConstraints(maxHeight: 200, maxWidth: 260),
                                                child: Image.network(
                                                  imageUrl,
                                                  fit: BoxFit.cover,
                                                  loadingBuilder: (context, child, progress) {
                                                    if (progress == null) return child;
                                                    return Container(
                                                      height: 120,
                                                      alignment: Alignment.center,
                                                      child: const CircularProgressIndicator(strokeWidth: 2),
                                                    );
                                                  },
                                                  errorBuilder: (_, __, ___) => Container(
                                                    padding: const EdgeInsets.all(8),
                                                    color: Colors.red.withOpacity(0.2),
                                                    child: Row(
                                                      mainAxisSize: MainAxisSize.min,
                                                      children: [
                                                        const Icon(Icons.broken_image, color: Colors.redAccent, size: 16),
                                                        const SizedBox(width: 6),
                                                        Text(_locale == 'ru' ? 'Ошибка загрузки' : 'Load failed', style: const TextStyle(color: Colors.redAccent, fontSize: 10)),
                                                      ],
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                          const SizedBox(height: 4),
                                        ],
                                        // Message text
                                        if (msg['text'] != null && (msg['text'] as String).isNotEmpty)
                                          Text(
                                            msg['text'] ?? '',
                                            style: TextStyle(
                                              fontSize: _chatFontSize,
                                              color: Colors.white,
                                              height: 1.3,
                                            ),
                                          ),
                                        if (_showChatTimestamps) ...[
                                          const SizedBox(height: 3),
                                          Align(
                                            alignment: Alignment.bottomRight,
                                            child: Text(
                                              _formatMessageTime(msg['time']),
                                              style: TextStyle(
                                                fontSize: 9,
                                                color: isMe ? Colors.white.withOpacity(0.65) : Colors.white.withOpacity(0.35),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                ),
                                // Reactions display pills under message
                                if (reactions.isNotEmpty) ...[
                                  const SizedBox(height: 3),
                                  Wrap(
                                    spacing: 4,
                                    runSpacing: 4,
                                    children: reactions.entries.where((e) => e.value is List && (e.value as List).isNotEmpty).map((entry) {
                                      final emoji = entry.key;
                                      final users = List<dynamic>.from(entry.value);
                                      final hasReacted = users.contains(widget.username);
                                       return InkWell(
                                         onTap: () => _toggleReaction(msg['id'] ?? '', emoji),
                                         borderRadius: BorderRadius.circular(16),
                                         child: Container(
                                           padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
                                           decoration: BoxDecoration(
                                             color: hasReacted ? const Color(0xFF00F2FE).withOpacity(0.22) : const Color(0xFF222838).withOpacity(0.8),
                                             borderRadius: BorderRadius.circular(16),
                                             border: Border.all(
                                               color: hasReacted ? const Color(0xFF00F2FE).withOpacity(0.85) : Colors.white.withOpacity(0.12),
                                               width: 1,
                                             ),
                                             boxShadow: [
                                               BoxShadow(
                                                 color: Colors.black.withOpacity(0.2),
                                                 blurRadius: 4,
                                                 offset: const Offset(0, 1),
                                               ),
                                             ],
                                           ),
                                           child: Row(
                                             mainAxisSize: MainAxisSize.min,
                                             children: [
                                               Text(emoji, style: const TextStyle(fontSize: 12.5)),
                                               const SizedBox(width: 4),
                                               Text(
                                                 '${users.length}',
                                                 style: TextStyle(
                                                   fontSize: 11,
                                                   fontWeight: FontWeight.bold,
                                                   color: hasReacted ? const Color(0xFF00F2FE) : Colors.white70,
                                                 ),
                                               ),
                                             ],
                                           ),
                                         ),
                                       );
                                    }).toList(),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
              // Floating scroll to bottom button
              if (_showScrollToBottom)
                Positioned(
                  bottom: 8,
                  right: 8,
                  child: FloatingActionButton.small(
                    backgroundColor: const Color(0xFF1E2028),
                    foregroundColor: const Color(0xFF00F2FE),
                    elevation: 4,
                    shape: const CircleBorder(side: BorderSide(color: Color(0xFF00F2FE), width: 1.5)),
                    onPressed: () => _scrollChatToBottom(animate: true),
                    child: const Icon(Icons.arrow_downward_rounded, size: 18),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        // Replying preview banner
        if (_replyingTo != null)
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFF1A1F2C),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFF00F2FE).withOpacity(0.35)),
            ),
            child: Row(
              children: [
                Container(
                  width: 3,
                  height: 28,
                  decoration: BoxDecoration(
                    color: const Color(0xFF00F2FE),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 8),
                const Icon(Icons.reply_rounded, size: 18, color: Color(0xFF00F2FE)),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _replyingTo!['sender'] ?? '',
                        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF00F2FE)),
                      ),
                      Text(
                        _replyingTo!['text'] ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 10.5, color: Colors.white70),
                      ),
                    ],
                  ),
                ),
                InkWell(
                  onTap: () => setState(() => _replyingTo = null),
                  borderRadius: BorderRadius.circular(12),
                  child: const Padding(
                    padding: EdgeInsets.all(4),
                    child: Icon(Icons.close, size: 16, color: Colors.white60),
                  ),
                ),
              ],
            ),
          ),
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
              // Attachment button (Photos, GIFs, Links)
              InkWell(
                onTap: _isUploadingImage ? null : _showMediaAttachmentPicker,
                borderRadius: BorderRadius.circular(20),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  child: _isUploadingImage
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF00F2FE)))
                      : const Icon(Icons.add_photo_alternate_outlined, size: 20, color: Color(0xFF00F2FE)),
                ),
              ),
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
              const SizedBox(width: 6),
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
        ),
      ),
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

          // Preferred Quality selector
          _buildCard(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Flexible(
                  child: Text(
                    _loc('preferredQualityLabel'),
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                DropdownButton<String>(
                  value: _preferredQuality,
                  dropdownColor: const Color(0xFF161426),
                  style: const TextStyle(fontSize: 12, color: Colors.white),
                  items: const [
                    DropdownMenuItem(value: 'Auto', child: Text('Auto')),
                    DropdownMenuItem(value: '1080p', child: Text('1080p (FHD)')),
                    DropdownMenuItem(value: '720p', child: Text('720p (HD)')),
                    DropdownMenuItem(value: '480p', child: Text('480p (SD)')),
                  ],
                  onChanged: (val) {
                    if (val != null) {
                      setState(() {
                        _preferredQuality = val;
                      });
                      saveSettings({'preferredQuality': val});
                    }
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // Sync Tolerance selector
          _buildCard(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Flexible(
                  child: Text(
                    _loc('syncTolerance'),
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                DropdownButton<double>(
                  value: _syncToleranceSec,
                  dropdownColor: const Color(0xFF161426),
                  style: const TextStyle(fontSize: 12, color: Colors.white),
                  items: [
                    DropdownMenuItem(value: 1.0, child: Text(_locale == 'ru' ? '1.0 сек (Точно)' : '1.0s (Precise)')),
                    DropdownMenuItem(value: 1.5, child: Text(_locale == 'ru' ? '1.5 сек (Высокая)' : '1.5s (High)')),
                    DropdownMenuItem(value: 2.0, child: Text(_locale == 'ru' ? '2.0 сек (Норма)' : '2.0s (Default)')),
                    DropdownMenuItem(value: 3.0, child: Text(_locale == 'ru' ? '3.0 сек (Мягкая)' : '3.0s (Relaxed)')),
                    DropdownMenuItem(value: 5.0, child: Text(_locale == 'ru' ? '5.0 сек (Для медл. сети)' : '5.0s (Slow net)')),
                  ],
                  onChanged: (val) {
                    if (val != null) {
                      setState(() {
                        _syncToleranceSec = val;
                      });
                      saveSettings({'syncToleranceSec': val});
                    }
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // System Messages Switch
          _buildCard(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Flexible(
                  child: Text(
                    _loc('showSystemMessages'),
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Switch(
                  value: _showSystemMessages,
                  activeColor: const Color(0xFF00F2FE),
                  onChanged: (val) {
                    setState(() {
                      _showSystemMessages = val;
                    });
                    saveSettings({'showSystemMessages': val});
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // Show Chat Timestamps Switch
          _buildCard(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Flexible(
                  child: Text(
                    _loc('showTimestamps'),
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Switch(
                  value: _showChatTimestamps,
                  activeColor: const Color(0xFF00F2FE),
                  onChanged: (val) {
                    setState(() {
                      _showChatTimestamps = val;
                    });
                    saveSettings({'showChatTimestamps': val});
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // Chat Sound Alerts Switch
          _buildCard(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Flexible(
                  child: Text(
                    _loc('chatSounds'),
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Switch(
                  value: _chatSounds,
                  activeColor: const Color(0xFF00F2FE),
                  onChanged: (val) {
                    setState(() {
                      _chatSounds = val;
                    });
                    saveSettings({'chatSounds': val});
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // Auto-scroll Chat Switch
          _buildCard(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Flexible(
                  child: Text(
                    _loc('autoScrollChat'),
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Switch(
                  value: _autoScrollChat,
                  activeColor: const Color(0xFF00F2FE),
                  onChanged: (val) {
                    setState(() {
                      _autoScrollChat = val;
                    });
                    saveSettings({'autoScrollChat': val});
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // Compact Chat View Switch
          _buildCard(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Flexible(
                  child: Text(
                    _loc('compactChat'),
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Switch(
                  value: _compactChat,
                  activeColor: const Color(0xFF00F2FE),
                  onChanged: (val) {
                    setState(() {
                      _compactChat = val;
                    });
                    saveSettings({'compactChat': val});
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // Check for updates button
          _buildCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      _locale == 'ru' ? 'Версия приложения' : 'App Version',
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: const Color(0xFF6C63FF).withOpacity(0.2),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        globalAppVersion,
                        style: TextStyle(fontSize: 10, color: Colors.white.withOpacity(0.5), fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                () {
                  bool isCheckingUpdates = false;
                  return StatefulBuilder(
                    builder: (ctx, setLocalState) {
                      return ElevatedButton.icon(
                        onPressed: isCheckingUpdates ? null : () async {
                          setLocalState(() => isCheckingUpdates = true);
                          try {
                            final verUrl = 'http://luna.lumigrid.ru:3000/version';
                            final response = await http.get(Uri.parse(verUrl)).timeout(const Duration(seconds: 5));
                            if (response.statusCode == 200) {
                              final jsonData = jsonDecode(response.body) as Map<String, dynamic>;
                              final latestVersion = jsonData['latest_version'] as String? ?? '';
                              final currentVersion = globalAppVersion;
                              if (latestVersion.isNotEmpty && isNewerVersion(latestVersion, currentVersion)) {
                                String downloadUrl = jsonData['windows_url'] as String? ?? '';
                              if (!mounted) return;
                              showDialog(
                                context: context,
                                builder: (ctx) => AlertDialog(
                                  backgroundColor: const Color(0xFF161426),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                                  title: Text(_locale == 'ru' ? 'Доступно обновление! 🚀' : 'Update Available! 🚀',
                                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                                  content: Text(
                                    _locale == 'ru'
                                        ? 'Доступна новая версия v$latestVersion (текущая v$globalAppVersion).\nХотите обновиться?'
                                        : 'A new version v$latestVersion is available (current v$globalAppVersion).\nDo you want to update?',
                                    style: const TextStyle(color: Colors.white70),
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () => Navigator.of(ctx).pop(),
                                      child: Text(_locale == 'ru' ? 'Позже' : 'Later',
                                        style: const TextStyle(color: Colors.white54)),
                                    ),
                                    ElevatedButton.icon(
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: const Color(0xFF6C63FF),
                                        foregroundColor: Colors.white,
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                      ),
                                      icon: const Icon(Icons.downloading, size: 16),
                                      onPressed: () async {
                                        Navigator.of(ctx).pop();
                                        if (downloadUrl.isNotEmpty) {
                                          downloadAndInstallUpdateWindows(context, downloadUrl, latestVersion, locale: _locale);
                                        }
                                      },
                                      label: Text(_locale == 'ru' ? 'Авто-Обновление v$latestVersion' : 'Auto-Install v$latestVersion',
                                        style: const TextStyle(fontWeight: FontWeight.bold)),
                                    ),
                                  ],
                                ),
                              );
                            } else {
                              if (!mounted) return;
                              /* SnackBar disabled */
                            }
                          } else {
                            throw Exception('HTTP ${response.statusCode}');
                          }
                        } catch (e) {
                          if (!mounted) return;
                          /* SnackBar disabled */
                        } finally {
                          setLocalState(() => isCheckingUpdates = false);
                        }
                      },
                      icon: isCheckingUpdates
                          ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : const Icon(Icons.system_update_alt, size: 14),
                      label: Text(
                        isCheckingUpdates
                            ? (_locale == 'ru' ? 'Проверка...' : 'Checking...')
                            : (_locale == 'ru' ? 'Проверить обновления' : 'Check for Updates'),
                        style: const TextStyle(fontSize: 12),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF6C63FF),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    );
                  },
                );
              }(),
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],
      ),
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
                ),
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

  // Users Dialog for mobile & desktop
  void _showUsersDialog() {
    showDialog(
      context: context,
      builder: (dialogCtx) {
        return ValueListenableBuilder<List<dynamic>>(
          valueListenable: _usersNotifier,
          builder: (context, currentUsers, _) {
            final isMeHost = _isHost;
            return AlertDialog(
              title: Row(
                children: [
                  const Icon(Icons.people_alt_outlined, color: Color(0xFF00F2FE), size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${_loc('activeUsers')} (${currentUsers.length})',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
              backgroundColor: const Color(0xFF161426),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              content: SizedBox(
                width: 320,
                height: 350,
                child: currentUsers.isEmpty
                    ? Center(
                        child: Text(
                          _loc('noParticipants'),
                          style: TextStyle(color: Colors.white.withOpacity(0.5)),
                        ),
                      )
                    : ListView.separated(
                        itemCount: currentUsers.length,
                        separatorBuilder: (_, __) => Divider(color: Colors.white.withOpacity(0.06), height: 1),
                        itemBuilder: (context, index) {
                          final user = currentUsers[index];
                          final isMe = user['id'] == _socket.id;
                          final isHost = user['isHost'] == true ||
                              (_hostUsername != null &&
                                  (user['username'] as String).toLowerCase() == _hostUsername!.toLowerCase()) ||
                              index == 0;

                          return ListTile(
                            contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                            leading: CircleAvatar(
                              radius: 18,
                              backgroundColor: isHost ? const Color(0xFF00F2FE) : const Color(0xFF6C63FF),
                              child: Text(
                                (user['username'] as String).isNotEmpty
                                    ? (user['username'] as String).substring(0, 1).toUpperCase()
                                    : '?',
                                style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 13),
                              ),
                            ),
                            title: Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    user['username'] as String,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontWeight: isMe ? FontWeight.bold : FontWeight.normal,
                                      color: isMe ? const Color(0xFF00F2FE) : Colors.white,
                                    ),
                                  ),
                                ),
                                if (isMe) ...[
                                  const SizedBox(width: 4),
                                  Text(
                                    _locale == 'ru' ? ' (Вы)' : ' (You)',
                                    style: const TextStyle(color: Color(0xFF00F2FE), fontSize: 12, fontWeight: FontWeight.bold),
                                  ),
                                ],
                              ],
                            ),
                            trailing: isHost
                                ? Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: Colors.amber.withOpacity(0.2),
                                      border: Border.all(color: Colors.amber.withOpacity(0.5)),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Text(
                                      _loc('hostLabel'),
                                      style: const TextStyle(fontSize: 10, color: Colors.amber, fontWeight: FontWeight.bold),
                                    ),
                                  )
                                : (isMeHost && !isMe
                                    ? Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          IconButton(
                                            icon: const Icon(Icons.exit_to_app, color: Colors.orangeAccent, size: 20),
                                            tooltip: _loc('kickTooltip'),
                                            onPressed: () => _kickUser(user['id']),
                                          ),
                                          IconButton(
                                            icon: const Icon(Icons.block, color: Colors.redAccent, size: 20),
                                            tooltip: _loc('banTooltip'),
                                            onPressed: () => _banUser(user['id']),
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
                  onPressed: () => Navigator.pop(dialogCtx),
                  child: Text(_loc('close'), style: const TextStyle(color: Color(0xFF00F2FE))),
                ),
              ],
            );
          },
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
