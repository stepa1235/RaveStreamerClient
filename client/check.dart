  }

  // Set up video player with a specific URL (uses media_kit which supports HLS natively)
  Future<void> _setupVideoPlayer(String url, String name, {bool startPlaying = false, double startSeconds = 0.0, Map<String, dynamic>? headers, String? iframeUrl}) async {
    if (_isDisposed || !mounted) return;
    
    // Dispose previous player
    if (_mkPlayer != null) {
      await _mkPlayer!.dispose();
      if (_isDisposed || !mounted) return;
      setState(() {
        _mkPlayer = null;
        _mkController = null;
        _isPlayerVisible = false;
      });
    }

    setState(() {
      _currentVideoUrl = url;
      _currentVideoName = name;
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
            content: Text(_locale == 'ru' ? 'РР·РІР»РµС‡РµРЅРёРµ РєР°С‡РµСЃС‚РІР° $_preferredQuality...' : 'Extracting $_preferredQuality...'),
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
              content: Text(_locale == 'ru' ? 'Р›РѕРєР°Р»СЊРЅРѕРµ РёР·РІР»РµС‡РµРЅРёРµ РЅРµ СѓРґР°Р»РѕСЃСЊ...' : 'Local extraction failed...'),
              duration: const Duration(seconds: 2),
            ),
          );
        }
      }
    } else if (lowercaseUrl.startsWith('http') && !url.contains('/video?path=')) {
      // If it's already a direct video stream, skip extraction
      if (lowercaseUrl.contains('.m3u8') || lowercaseUrl.contains('.mp4') || lowercaseUrl.contains('.webm')) {
        playUrl = url;
      } else {
        // Non-YouTube web link: extract via server (server handles CDN auth)
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(_locale == 'ru' ? 'РР·РІР»РµС‡РµРЅРёРµ РІРёРґРµРѕРїРѕС‚РѕРєР°...' : 'Extracting video stream...'),
              duration: const Duration(seconds: 5),
            ),
          );
        }
        try {
        final queryUrl = iframeUrl ?? url;
        final extractUri = Uri.parse('${widget.serverUrl}/extract?url=${Uri.encodeComponent(queryUrl)}');
        final response = await http.get(
          extractUri,
          headers: {'bypass-tunnel-reminder': 'true'},
        ).timeout(const Duration(seconds: 120));
        
        if (response.statusCode == 200) {
          final data = jsonDecode(response.body) as Map<String, dynamic>;
          if (data['success'] == true && data['url'] != null) {
            final rawUrl = data['url'] as String;
            playUrl = rawUrl.startsWith('/') ? '${widget.serverUrl}$rawUrl' : rawUrl;
            
            if (data['alternatives'] != null && iframeUrl == null) {
               setState(() {
                 _availablePlayers = data['alternatives'];
                 _selectedPlayerName = 'Full HD';
               });
            }
            if (data['referer'] != null) {
              playerHeaders['Referer'] = data['referer'];
              try {
                playerHeaders['Origin'] = Uri.parse(data['referer']).origin;
              } catch (_) {}
            }
            if (data['cookies'] != null && data['cookies'].toString().isNotEmpty) {
              playerHeaders['Cookie'] = data['cookies'];
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
    }

    // For direct CDN URLs (not our proxy), add Referer/Cookie headers if not already set
    if (!playUrl.contains('/proxy/') && !playerHeaders.containsKey('Referer')) {
      try {
        final playUri = Uri.parse(playUrl);
        playerHeaders['Referer'] = '${playUri.scheme}://${playUri.host}/';
        playerHeaders['Origin'] = '${playUri.scheme}://${playUri.host}';
      } catch (_) {}
    }

    // Merge any extra headers from socket events
    if (headers != null) {
      headers.forEach((key, value) {
        playerHeaders[key] = value.toString();
      });
    }

    debugPrint('[media_kit] Opening: $playUrl');

    try {
      final player = Player();
      final controller = VideoController(player);

      // Open media with httpHeaders so libmpv passes them to CDN requests (incl. HLS segments)
      await player.open(
        Media(playUrl, httpHeaders: playerHeaders),
        play: false,
      );

      if (_isDisposed || !mounted) {
        player.dispose();
        return;
      }

      setState(() {
        _mkPlayer = player;
        _mkController = controller;
        _isPlayerVisible = true;
      });

      // Seek if needed
      if (startSeconds > 0.0) {
        await player.seek(Duration(milliseconds: (startSeconds * 1000).toInt()));
      }

      if (startPlaying) {
        await player.play();
      }

      // Listen for end-of-stream to auto-skip to next in queue
      player.stream.completed.listen((completed) {
        if (!completed || _isDisposed || !mounted) return;
        final isHost = _users.isNotEmpty && _users[0]['id'] == _socket.id;
        if (isHost) {
          _socket.emit('skip-video', {'roomId': widget.roomId});
        }
      });

      // Refresh UI on playback state change
      player.stream.playing.listen((_) { if (mounted) setState(() {}); });
      player.stream.position.listen((_) { if (mounted) setState(() {}); });
      player.stream.duration.listen((_) { if (mounted) setState(() {}); });

    } catch (e) {
      if (!mounted) return;
      debugPrint('Error initializing media_kit player: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to load video: $e'), backgroundColor: Colors.red),
      );
    }
  }

  Future<String?> getYoutubeStreamUrl(String youtubeUrl) async {
    try {
      final appData = Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path;
      final dir = Directory('$appData\\RaveStreamer');
      if (!dir.existsSync()) dir.createSync(recursive: true);
