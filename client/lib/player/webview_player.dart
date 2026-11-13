import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:webview_windows/webview_windows.dart';

class Media {
  final String resource;
  final Map<String, String>? httpHeaders;
  Media(this.resource, {this.httpHeaders});
}

class PlayerTrack {
  final int id;
  final String name;
  final String lang;
  final bool isNative;
  final int? nativeIndex;

  PlayerTrack({
    required this.id,
    required this.name,
    this.lang = '',
    this.isNative = false,
    this.nativeIndex,
  });

  factory PlayerTrack.fromJson(Map<String, dynamic> json) {
    return PlayerTrack(
      id: json['id'] as int? ?? 0,
      name: json['name'] as String? ?? 'Track',
      lang: json['lang'] as String? ?? '',
      isNative: json['isNative'] as bool? ?? false,
      nativeIndex: json['nativeIndex'] as int?,
    );
  }
}

class WebviewPlayerState {
  int readyState = 0;
  bool playing = false;
  Duration position = Duration.zero;
  Duration duration = Duration.zero;
  int volume = 100;
  double playbackRate = 1.0;

  List<PlayerTrack> audioTracks = [];
  List<PlayerTrack> subtitleTracks = [];
  int currentAudioTrack = -1;
  int currentSubtitleTrack = -1;
}

class WebviewPlayerStream {
  final _completedController = StreamController<bool>.broadcast();
  final _errorController = StreamController<dynamic>.broadcast();
  final _playingController = StreamController<bool>.broadcast();
  final _positionController = StreamController<Duration>.broadcast();
  final _durationController = StreamController<Duration>.broadcast();
  final _tracksController = StreamController<Map<String, dynamic>>.broadcast();
  final _rateController = StreamController<double>.broadcast();
  final _logController = StreamController<dynamic>.broadcast();

  Stream<bool> get completed => _completedController.stream;
  Stream<dynamic> get error => _errorController.stream;
  Stream<bool> get playing => _playingController.stream;
  Stream<Duration> get position => _positionController.stream;
  Stream<Duration> get duration => _durationController.stream;
  Stream<Map<String, dynamic>> get tracks => _tracksController.stream;
  Stream<double> get rate => _rateController.stream;
  Stream<dynamic> get log => _logController.stream;
}

class WebviewPlayer {
  final WebviewController controller = WebviewController();
  final state = WebviewPlayerState();
  final stream = WebviewPlayerStream();
  bool _isInitialized = false;
  HttpServer? _localServer;
  int _localPort = 0;
  final String _accessToken = base64UrlEncode(List<int>.generate(32, (_) => Random.secure().nextInt(256)));
  String? _allowedLocalFile;
  String? _customSubtitlesVtt;

  int get localPort => _localPort;

  void _logToFile(String msg) {
    try {
      final file = File('C:\\RaveStreamer\\client_debug.log');
      file.writeAsStringSync('${DateTime.now().toIso8601String()} [webview_player] $msg\n', mode: FileMode.append);
    } catch (_) {}
  }

  Future<void> initialize() async {
    try {
      // Bind to localhost on a random free port to serve HTML player
      _localServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _localPort = _localServer!.port;
      _logToFile('Local server started on port $_localPort');

      _localServer!.listen((HttpRequest request) async {
        final path = request.uri.path;
        final clientIp = request.connectionInfo?.remoteAddress.address ?? 'unknown';

        // A random port alone does not protect local files from hostile websites.
        if (request.uri.queryParameters['key'] != _accessToken) {
          request.response.statusCode = HttpStatus.forbidden;
          await request.response.close();
          return;
        }
        // Add CORS headers for player safety
        request.response.headers.add('Access-Control-Allow-Origin', '*');
        request.response.headers.add('Access-Control-Allow-Headers', '*');
        request.response.headers.add('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');

        if (request.method == 'OPTIONS') {
          request.response.statusCode = HttpStatus.ok;
          request.response.close();
          return;
        }

        if (path == '/subtitles.vtt') {
          request.response.headers.contentType = ContentType('text', 'vtt', charset: 'utf-8');
          request.response.write(_customSubtitlesVtt ?? 'WEBVTT\n\n');
          request.response.close();
          return;
        }

        if (path == '/local-file') {
          final filePath = request.uri.queryParameters['path'];
          if (filePath == null || filePath != _allowedLocalFile) {
            request.response.statusCode = HttpStatus.badRequest;
            request.response.close();
            return;
          }
          final file = File(filePath);
          if (!await file.exists()) {
            request.response.statusCode = HttpStatus.notFound;
            request.response.close();
            return;
          }
          final length = await file.length();
          final rangeHeader = request.headers.value('range');

          request.response.headers.add('Accept-Ranges', 'bytes');
          request.response.headers.contentType = ContentType('video', 'mp4');

          if (rangeHeader != null && rangeHeader.startsWith('bytes=')) {
            final parts = rangeHeader.substring(6).split('-');
            final suffix = parts[0].isEmpty;
            final first = int.tryParse(parts[0]);
            final last = parts.length == 2 ? int.tryParse(parts[1]) : null;
            if (parts.length != 2 || length == 0 ||
                (suffix ? last == null || last <= 0 : first == null || first < 0 || first >= length) ||
                (!suffix && parts[1].isNotEmpty && (last == null || last < first!))) {
              request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
              request.response.headers.set('Content-Range', 'bytes */$length');
              await request.response.close();
              return;
            }
            final start = suffix ? max(0, length - last!) : first!;
            final end = suffix ? length - 1 : min(last ?? length - 1, length - 1);
            final contentLength = end - start + 1;

            request.response.statusCode = HttpStatus.partialContent;
            request.response.headers.set('Content-Range', 'bytes $start-$end/$length');
            request.response.contentLength = contentLength;

            await file.openRead(start, end + 1).pipe(request.response);
          } else {
            request.response.contentLength = length;
            await file.openRead().pipe(request.response);
          }
          return;
        }

        if (path == '/proxy') {
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

          _logToFile('Proxy Request from $clientIp: $urlParam (Range: ${request.headers.value('range')})');

          final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
          try {
            var targetUri = Uri.parse(urlParam);
            HttpClientRequest? targetRequest;
            HttpClientResponse? targetResponse;

            // Loop up to 10 times to follow redirects internally
            for (var redirectCount = 0; redirectCount < 10; redirectCount++) {
              _logToFile('Proxy routing hop #$redirectCount to $targetUri');
              targetRequest = await client.getUrl(targetUri);
              targetRequest.followRedirects = false;

              final rangeHeader = request.headers.value('range');
              if (rangeHeader != null) {
                targetRequest.headers.set('Range', rangeHeader);
              }

              final userAgent = request.headers.value('user-agent') ??
                  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
              targetRequest.headers.set('User-Agent', userAgent);
              targetRequest.headers.set('Accept', '*/*');
              targetRequest.headers.set('Accept-Language', 'ru-RU,ru;q=0.9');
              targetRequest.headers.set('bypass-tunnel-reminder', 'true');
              targetRequest.headers.set('Bypass-Tunnel-Reminder', 'true');

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
              _logToFile('Hop #$redirectCount Response status: ${targetResponse.statusCode}');

              if (targetResponse.statusCode == 301 ||
                  targetResponse.statusCode == 302 ||
                  targetResponse.statusCode == 303 ||
                  targetResponse.statusCode == 307 ||
                  targetResponse.statusCode == 308) {
                final loc = targetResponse.headers.value('location');
                if (loc != null) {
                  try {
                    final resolvedLoc = targetUri.resolve(loc);
                    _logToFile('Hop #$redirectCount Redirect location header: $loc resolved to $resolvedLoc');
                    targetUri = resolvedLoc;
                    continue;
                  } catch (e) {
                    _logToFile('Hop #$redirectCount failed resolving redirect URI: $e');
                  }
                }
              }
              break;
            }

            request.response.statusCode = targetResponse!.statusCode;

            _logToFile('Proxy forwarding response headers:');
            targetResponse.headers.forEach((name, values) {
              final lowerName = name.toLowerCase();
              if (lowerName == 'transfer-encoding' ||
                  lowerName == 'content-encoding' ||
                  lowerName == 'access-control-allow-origin') {
                return;
              }
              if (lowerName == 'content-length') {
                try {
                  request.response.contentLength = int.parse(values.first);
                  _logToFile(' -> Content-Length: ${values.first}');
                } catch (_) {}
                return;
              }
              if (lowerName == 'location') return;

              for (var value in values) {
                request.response.headers.add(name, value);
              }
              _logToFile(' -> $name: ${values.join(', ')}');
            });

            final contentType = targetResponse.headers.value('content-type') ?? '';
            final isPlaylist = contentType.contains('mpegurl') ||
                contentType.contains('x-mpegurl') ||
                urlParam.contains('.m3u8');

            if (isPlaylist) {
              _logToFile('Proxy serving as playlist (HLS)...');
              final bytes = await targetResponse.fold<List<int>>([], (p, e) => p..addAll(e));
              final text = utf8.decode(bytes);

              final rewritten = text.split('\n').map((line) {
                final trimmed = line.trim();
                if (trimmed.isEmpty) return line;

                if (trimmed.startsWith('#')) {
                  return trimmed.replaceAllMapped(RegExp(r'URI="([^"]+)"'), (match) {
                    final p1 = match.group(1)!;
                    var absUrl = p1;
                    try {
                      absUrl = Uri.parse(targetUri.toString()).resolve(p1).toString();
                    } catch (_) {}

                    final proxyUrl =
                        'http://127.0.0.1:$_localPort/proxy?key=$_accessToken&url=${Uri.encodeComponent(absUrl)}&cookies=${Uri.encodeComponent(cookiesParam ?? '')}&referer=${Uri.encodeComponent(refererParam ?? '')}';
                    return 'URI="$proxyUrl"';
                  });
                }

                var absUrl = trimmed;
                try {
                  absUrl = Uri.parse(targetUri.toString()).resolve(trimmed).toString();
                } catch (_) {}

                return 'http://127.0.0.1:$_localPort/proxy?key=$_accessToken&url=${Uri.encodeComponent(absUrl)}&cookies=${Uri.encodeComponent(cookiesParam ?? '')}&referer=${Uri.encodeComponent(refererParam ?? '')}';
              }).join('\n');

              request.response.headers.contentType = ContentType('application', 'vnd.apple.mpegurl');
              request.response.write(rewritten);
              request.response.close();
              _logToFile('Proxy playlist rewrite & pipe complete.');
            } else {
              _logToFile('Proxy streaming binary chunk...');
              await targetResponse.pipe(request.response);
              _logToFile('Proxy chunk streaming complete.');
            }
          } catch (e) {
            _logToFile('Local proxy server error: $e');
            request.response.statusCode = HttpStatus.internalServerError;
            request.response.write('Local proxy error');
            request.response.close();
          } finally {
            client.close(force: true);
          }
        } else {
          request.response.headers.contentType = ContentType.html;
          request.response.write(_htmlPlayerCode);
          request.response.close();
        }
      });
      debugPrint('[webview] Local server running on port $_localPort');
    } catch (e) {
      debugPrint('[webview] Failed to start local server: $e');
    }

    try {
      await WebviewController.initializeEnvironment(
        additionalArguments: '--disable-web-security --autoplay-policy=no-user-gesture-required',
      );
    } catch (e) {
      debugPrint('[webview] Environment initialization error: $e');
    }

    try {
      await controller.initialize();
      _isInitialized = true;
    } catch (e) {
      debugPrint('[webview] controller.initialize() error: $e');
      _isInitialized = false;
    }

    controller.webMessage.listen((dynamic event) {
      if (event is String) {
        try {
          final data = jsonDecode(event) as Map<String, dynamic>;
          final type = data['type'] as String?;
          if (type == 'state') {
            state.readyState = data['readyState'] as int? ?? 0;
            state.playing = data['playing'] as bool? ?? false;
            state.position = Duration(milliseconds: data['position'] as int? ?? 0);
            state.duration = Duration(milliseconds: data['duration'] as int? ?? 0);
            state.volume = data['volume'] as int? ?? 100;
            state.playbackRate = (data['rate'] as num?)?.toDouble() ?? 1.0;

            stream._playingController.add(state.playing);
            stream._positionController.add(state.position);
            stream._durationController.add(state.duration);
            stream._rateController.add(state.playbackRate);
          } else if (type == 'tracks') {
            final audios = (data['audioTracks'] as List<dynamic>?)
                    ?.map((e) => PlayerTrack.fromJson(e as Map<String, dynamic>))
                    .toList() ??
                [];
            final subs = (data['subtitleTracks'] as List<dynamic>?)
                    ?.map((e) => PlayerTrack.fromJson(e as Map<String, dynamic>))
                    .toList() ??
                [];
            state.audioTracks = audios;
            state.subtitleTracks = subs;
            state.currentAudioTrack = data['currentAudio'] as int? ?? -1;
            state.currentSubtitleTrack = data['currentSubtitle'] as int? ?? -1;

            stream._tracksController.add({
              'audioTracks': audios,
              'subtitleTracks': subs,
              'currentAudio': state.currentAudioTrack,
              'currentSubtitle': state.currentSubtitleTrack,
            });
          } else if (type == 'ended') {
            stream._completedController.add(true);
          } else if (type == 'log') {
            final msg = data['message'] as String? ?? '';
            debugPrint('[JS Console] $msg');
            _logToFile('[JS Console] $msg');
          } else if (type == 'error') {
            final msg = data['message'] as String? ?? '';
            stream._errorController.add(msg);
            _logToFile('[JS Error] $msg');
          }
        } catch (e) {
          debugPrint('[webview] Event parsing error: $e');
        }
      }
    });

    if (_localPort > 0) {
      await controller.loadUrl('http://127.0.0.1:$_localPort/?key=$_accessToken');
    } else {
      await controller.loadStringContent(_htmlPlayerCode);
    }
  }

  Future<void> open(Media media, {bool play = false, double startSeconds = 0}) async {
    state.readyState = 0;
    if (!_isInitialized) return;

    final headers = <String, String>{};
    if (media.httpHeaders != null) {
      media.httpHeaders!.forEach((k, v) {
        headers[k] = v.toString();
      });
    }

    var playUrl = media.resource;
    final isHttp = playUrl.startsWith('http') && !playUrl.startsWith('http://127.0.0.1');
    final isYouTube = playUrl.contains('youtube.com') ||
        playUrl.contains('youtu.be') ||
        playUrl.contains('googlevideo.com');
    final isLiveStream = playUrl.contains('/live-stream/');

    _allowedLocalFile = null;
    if (!playUrl.startsWith('http')) {
      _allowedLocalFile = playUrl;
      playUrl = 'http://127.0.0.1:$_localPort/local-file?key=$_accessToken&path=${Uri.encodeComponent(playUrl)}';
    } else if (isHttp && !isYouTube && !isLiveStream) {
      if (playUrl.contains('/proxy/hls')) {
        try {
          final uri = Uri.parse(playUrl);
          final targetUrl = uri.queryParameters['url'] ?? '';
          final cookies = uri.queryParameters['cookies'] ?? '';
          final referer = uri.queryParameters['referer'] ?? '';
          if (targetUrl.isNotEmpty) {
            playUrl =
                'http://127.0.0.1:$_localPort/proxy?key=$_accessToken&url=${Uri.encodeComponent(targetUrl)}&cookies=${Uri.encodeComponent(cookies)}&referer=${Uri.encodeComponent(referer)}';
          }
        } catch (_) {}
      } else {
        final cookies = headers['Cookie'] ?? '';
        final referer = headers['Referer'] ?? '';
        playUrl =
            'http://127.0.0.1:$_localPort/proxy?key=$_accessToken&url=${Uri.encodeComponent(playUrl)}&cookies=${Uri.encodeComponent(cookies)}&referer=${Uri.encodeComponent(referer)}';
      }
    }

    final cmd = {
      'action': 'load',
      'url': playUrl,
      'headers': headers,
      'play': play,
      'startSeconds': startSeconds,
    };

    await controller.postWebMessage(jsonEncode(cmd));
  }

  Future<void> play() async {
    if (!_isInitialized) return;
    await controller.postWebMessage(jsonEncode({'action': 'play'}));
  }

  Future<void> pause() async {
    if (!_isInitialized) return;
    await controller.postWebMessage(jsonEncode({'action': 'pause'}));
  }

  Future<void> seek(Duration duration) async {
    if (!_isInitialized) return;
    await controller.postWebMessage(jsonEncode({
      'action': 'seek',
      'time': duration.inMilliseconds / 1000.0,
    }));
  }

  Future<void> setVolume(double vol) async {
    if (!_isInitialized) return;
    await controller.postWebMessage(jsonEncode({
      'action': 'volume',
      'volume': vol.toInt(),
    }));
  }

  Future<void> setPlaybackRate(double rate) async {
    if (!_isInitialized) return;
    state.playbackRate = rate;
    await controller.postWebMessage(jsonEncode({
      'action': 'rate',
      'rate': rate,
    }));
  }

  Future<void> setAudioTrack(int index) async {
    if (!_isInitialized) return;
    state.currentAudioTrack = index;
    await controller.postWebMessage(jsonEncode({
      'action': 'setAudioTrack',
      'index': index,
    }));
  }

  Future<void> setSubtitleTrack(int index, {int? nativeIndex}) async {
    if (!_isInitialized) return;
    state.currentSubtitleTrack = index;
    await controller.postWebMessage(jsonEncode({
      'action': 'setSubtitleTrack',
      'index': index,
      'nativeIndex': nativeIndex,
    }));
  }

  Future<void> loadCustomSubtitlesContent(String vttOrSrtContent, {String label = 'Субтитры'}) async {
    if (!_isInitialized) return;
    String vtt = vttOrSrtContent;
    if (!vtt.trim().startsWith('WEBVTT')) {
      // Convert basic SRT to WebVTT format
      vtt = 'WEBVTT\n\n' + vtt.replaceAllMapped(RegExp(r'(\d\d:\d\d:\d\d),(\d{3})'), (m) => '${m[1]}.${m[2]}');
    }
    _customSubtitlesVtt = vtt;
    final subUrl = 'http://127.0.0.1:$_localPort/subtitles.vtt?key=$_accessToken&t=${DateTime.now().millisecondsSinceEpoch}';
    await controller.postWebMessage(jsonEncode({
      'action': 'loadCustomSubtitles',
      'url': subUrl,
      'label': label,
      'lang': 'ru'
    }));
  }

  Future<void> clearCustomSubtitles() async {
    if (!_isInitialized) return;
    _customSubtitlesVtt = null;
    await controller.postWebMessage(jsonEncode({
      'action': 'loadCustomSubtitles',
      'url': '',
    }));
  }

  Future<void> dispose() async {
    _localServer?.close(force: true);
    if (_isInitialized) {
      await controller.dispose();
    }
  }
}

const String _htmlPlayerCode = r'''
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <style>
    body, html {
      margin: 0; padding: 0; width: 100%; height: 100%;
      background: black; overflow: hidden;
    }
    video {
      width: 100%; height: 100%; object-fit: contain;
    }
    ::cue {
      background-color: rgba(0, 0, 0, 0.7);
      color: #ffffff;
      font-size: 1.2rem;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
      text-shadow: 0 1px 2px rgba(0,0,0,0.8);
      border-radius: 4px;
    }
  </style>
  <script src="https://cdn.jsdelivr.net/npm/hls.js@1"></script>
</head>
<body>
  <video id="player" autoplay playsinline></video>
  <script>
    const originalLog = console.log;
    console.log = function(...args) {
      originalLog.apply(console, args);
      try {
        window.chrome.webview.postMessage(JSON.stringify({
          type: 'log',
          message: args.join(' ')
        }));
      } catch(_) {}
    };

    const originalWarn = console.warn;
    console.warn = function(...args) {
      originalWarn.apply(console, args);
      try {
        window.chrome.webview.postMessage(JSON.stringify({
          type: 'log',
          message: '[WARN] ' + args.join(' ')
        }));
      } catch(_) {}
    };

    const originalError = console.error;
    console.error = function(...args) {
      originalError.apply(console, args);
      try {
        window.chrome.webview.postMessage(JSON.stringify({
          type: 'error',
          message: '[ERROR] ' + args.join(' ')
        }));
      } catch(_) {}
    };

    window.onerror = function(message, source, lineno, colno, error) {
      try {
        window.chrome.webview.postMessage(JSON.stringify({
          type: 'error',
          message: `Global JS error: ${message} at ${source}:${lineno}:${colno}`
        }));
      } catch(_) {}
      return false;
    };

    const video = document.getElementById('player');

    video.addEventListener('error', function(e) {
      try {
        const err = video.error;
        let errMsg = 'Unknown error';
        if (err) {
          switch (err.code) {
            case err.MEDIA_ERR_ABORTED: errMsg = 'Playback aborted'; break;
            case err.MEDIA_ERR_NETWORK: errMsg = 'Network error'; break;
            case err.MEDIA_ERR_DECODE: errMsg = 'Media decoding error'; break;
            case err.MEDIA_ERR_SRC_NOT_SUPPORTED: errMsg = 'Format/source not supported'; break;
          }
        }
        window.chrome.webview.postMessage(JSON.stringify({
          type: 'error',
          message: `HTML5 Video error: ${errMsg} (code: ${err ? err.code : 'unknown'})`
        }));
      } catch(_) {}
    });

    let hls = null;

    function sendState() {
      const state = {
        type: 'state',
        readyState: video.readyState,
        playing: !video.paused,
        position: Math.floor(video.currentTime * 1000),
        duration: Math.floor(video.duration * 1000) || 0,
        volume: Math.floor(video.volume * 100),
        rate: video.playbackRate || 1.0
      };
      window.chrome.webview.postMessage(JSON.stringify(state));
    }

    function sendTracks() {
      let audioList = [];
      let subList = [];
      if (hls && hls.audioTracks) {
        audioList = hls.audioTracks.map((t, i) => ({
          id: i,
          name: t.name || t.lang || ('Аудиодорожка ' + (i + 1)),
          lang: t.lang || ''
        }));
      }
      if (hls && hls.subtitleTracks) {
        subList = hls.subtitleTracks.map((t, i) => ({
          id: i,
          name: t.name || t.lang || ('Субтитры ' + (i + 1)),
          lang: t.lang || '',
          isNative: false
        }));
      }
      if (video.textTracks && video.textTracks.length > 0) {
        for (let i = 0; i < video.textTracks.length; i++) {
          const tt = video.textTracks[i];
          const name = tt.label || tt.language || ('Субтитры ' + (i + 1));
          if (!subList.some(s => s.name === name)) {
            subList.push({
              id: 1000 + i,
              name: name,
              lang: tt.language || '',
              isNative: true,
              nativeIndex: i
            });
          }
        }
      }
      window.chrome.webview.postMessage(JSON.stringify({
        type: 'tracks',
        audioTracks: audioList,
        subtitleTracks: subList,
        currentAudio: hls ? hls.audioTrack : -1,
        currentSubtitle: hls ? hls.subtitleTrack : -1
      }));
    }

    video.addEventListener('play', sendState);
    video.addEventListener('pause', sendState);
    let pendingSeek = null;
    video.addEventListener('loadedmetadata', () => {
      if (pendingSeek !== null) {
        video.currentTime = pendingSeek;
        pendingSeek = null;
      }
      sendState();
    });
    video.addEventListener('timeupdate', sendState);
    for (const event of ['loadstart', 'waiting', 'stalled', 'canplay', 'playing', 'seeking', 'seeked', 'emptied']) {
      video.addEventListener(event, sendState);
    }
    video.addEventListener('durationchange', sendState);
    video.addEventListener('volumechange', sendState);
    video.addEventListener('ratechange', sendState);
    video.addEventListener('ended', () => {
      window.chrome.webview.postMessage(JSON.stringify({ type: 'ended' }));
    });

    window.chrome.webview.addEventListener('message', function(e) {
      try {
        let cmd = typeof e.data === 'string' ? JSON.parse(e.data) : e.data;
        if (cmd.action === 'load') {
          pendingSeek = cmd.startSeconds > 0 ? cmd.startSeconds : null;
          const url = cmd.url;

          video.pause();
          video.removeAttribute('src');
          video.load();
          if (hls) {
            hls.destroy();
            hls = null;
          }

          const urlLower = url.toLowerCase();
          const isHls = urlLower.includes('.m3u8') || urlLower.includes('%2em3u8');
          const hasHls = typeof Hls !== 'undefined';
          if (hasHls && Hls.isSupported() && isHls) {
            console.log('Loading as HLS stream using Hls.js: ' + url);
            hls = new Hls({
              xhrSetup: function(xhr, segmentUrl) {
                try { xhr.setRequestHeader('bypass-tunnel-reminder', 'true'); } catch(_) {}
                if (cmd.headers) {
                  for (const key in cmd.headers) {
                    if (key.toLowerCase() !== 'host' && key.toLowerCase() !== 'user-agent') {
                      try { xhr.setRequestHeader(key, cmd.headers[key]); } catch(_) {}
                    }
                  }
                }
              }
            });
            hls.loadSource(url);
            hls.attachMedia(video);
            hls.on(Hls.Events.MANIFEST_PARSED, function() {
              console.log('HLS manifest parsed, playing video');
              sendTracks();
              if (cmd.play) video.play();
            });
            hls.on(Hls.Events.AUDIO_TRACKS_UPDATED, sendTracks);
            hls.on(Hls.Events.SUBTITLE_TRACKS_UPDATED, sendTracks);
            hls.on(Hls.Events.ERROR, function(event, data) {
              console.log('HLS.js error event: ' + data.type + ' / ' + data.details + ' fatal=' + data.fatal);
              if (data.fatal) {
                switch(data.type) {
                  case Hls.ErrorTypes.NETWORK_ERROR:
                    hls.startLoad();
                    break;
                  case Hls.ErrorTypes.MEDIA_ERROR:
                    hls.recoverMediaError();
                    break;
                  default:
                    hls.destroy();
                    video.src = url;
                    if (cmd.play) video.play();
                    break;
                }
              }
            });
          } else {
            console.log('Loading as direct native file source: ' + url);
            video.src = url;
            if (cmd.play) video.play();
            setTimeout(sendTracks, 500);
          }
        } else if (cmd.action === 'play') {
          video.play();
        } else if (cmd.action === 'pause') {
          video.pause();
        } else if (cmd.action === 'seek') {
          if (video.readyState === 0) pendingSeek = cmd.time;
          else video.currentTime = cmd.time;
        } else if (cmd.action === 'volume') {
          video.volume = cmd.volume / 100;
        } else if (cmd.action === 'rate') {
          video.playbackRate = cmd.rate;
        } else if (cmd.action === 'setAudioTrack') {
          if (hls && typeof cmd.index === 'number') {
            hls.audioTrack = cmd.index;
          }
        } else if (cmd.action === 'setSubtitleTrack') {
          if (hls && typeof cmd.index === 'number') {
            hls.subtitleTrack = cmd.index;
          }
          if (video.textTracks) {
            for (let i = 0; i < video.textTracks.length; i++) {
              video.textTracks[i].mode = (cmd.nativeIndex === i) ? 'showing' : 'disabled';
            }
          }
        } else if (cmd.action === 'loadCustomSubtitles') {
          const oldTracks = video.querySelectorAll('track.custom-sub');
          oldTracks.forEach(t => t.remove());
          if (cmd.url) {
            const track = document.createElement('track');
            track.className = 'custom-sub';
            track.kind = 'subtitles';
            track.label = cmd.label || 'Внешние субтитры';
            track.srclang = cmd.lang || 'ru';
            track.src = cmd.url;
            track.default = true;
            video.appendChild(track);
            track.addEventListener('load', function() {
              track.mode = 'showing';
              sendTracks();
            });
            setTimeout(sendTracks, 400);
          }
        }
      } catch (err) {
        window.chrome.webview.postMessage(JSON.stringify({
          type: 'error',
          message: err.toString()
        }));
      }
    });
  </script>
</body>
</html>
''';
