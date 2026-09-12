import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:socket_io_client/socket_io_client.dart' as io_client;
import 'package:flutter/foundation.dart';

class WebRTCManager {
  final io_client.Socket socket;
  final String roomId;
  final bool Function() isHostResolver;
  
  MediaStream? localStream;
  RTCVideoRenderer localRenderer = RTCVideoRenderer();
  RTCVideoRenderer remoteRenderer = RTCVideoRenderer();
  bool isPeerConnected = false;
  
  // Map of viewer Socket ID -> RTCPeerConnection
  final Map<String, RTCPeerConnection> peerConnections = {};
  final Map<String, List<Map<String, dynamic>>> _iceCandidateQueue = {};
  final Map<String, bool> _hasRemoteDescription = {};

  final Map<String, dynamic> configuration = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
      {'urls': 'stun:195.133.26.226:3478'},
      {
        'urls': [
          'turn:195.133.26.226:3478?transport=udp',
          'turn:195.133.26.226:3478?transport=tcp',
        ],
        'username': 'luna',
        'credential': 'luna2026secret',
      },
    ]
  };

  Function()? onStreamStarted;
  Function()? onStreamStopped;
  Function()? onRenderUpdated;
  Function(String)? onError;

  WebRTCManager({
    required this.socket, 
    required this.roomId, 
    required this.isHostResolver
  });

  Future<void> initialize() async {
    await localRenderer.initialize();
    await remoteRenderer.initialize();
    remoteRenderer.onResize = () {
      onRenderUpdated?.call();
    };

    // Listen to signaling events
    socket.on('webrtc-offer', _handleOffer);
    socket.on('webrtc-answer', _handleAnswer);
    socket.on('webrtc-ice-candidate', _handleIceCandidate);
  }

  // --- HOST SPECIFIC ---

  Future<void> startScreenShare({
    required String sourceId, 
    int fps = 30, 
    int width = 1280, 
    int height = 720
  }) async {
    if (!isHostResolver()) return;

    try {
      final mediaConstraints = {
        'audio': true,
        'video': {
          'deviceId': {'exact': sourceId},
          'mandatory': {
            'minFrameRate': fps.toString(),
            'minWidth': width.toString(),
            'minHeight': height.toString(),
          }
        }
      };

      try {
        localStream = await navigator.mediaDevices.getDisplayMedia(mediaConstraints);
      } catch (e) {
        debugPrint('Failed to getDisplayMedia: $e');
      }
      localRenderer.srcObject = localStream;
      
      socket.emit('start-stream', {'roomId': roomId});
      onStreamStarted?.call();
      
      // Stop stream if user stops sharing from OS UI
      final videoTracks = localStream?.getVideoTracks();
      if (videoTracks != null && videoTracks.isNotEmpty) {
        videoTracks.first.onEnded = () {
          stopScreenShare();
        };
      }
      
    } catch (e) {
      debugPrint('Error starting screen share: $e');
      onError?.call('Failed to capture screen: $e');
    }
  }

  Future<void> stopScreenShare() async {
    if (!isHostResolver()) return;
    
    socket.emit('stop-stream', {'roomId': roomId});
    
    localStream?.getTracks().forEach((track) => track.stop());
    localStream = null;
    localRenderer.srcObject = null;
    isPeerConnected = false;
    
    for (var pc in peerConnections.values) {
      pc.close();
    }
    peerConnections.clear();
    onStreamStopped?.call();
  }

  // Called when a new viewer joins the room (Host only)
  Future<void> createConnectionForViewer(String viewerId) async {
    if (!isHostResolver() || localStream == null) return;

    final pc = await createPeerConnection(configuration);
    peerConnections[viewerId] = pc;

    pc.onIceCandidate = (candidate) {
      socket.emit('webrtc-ice-candidate', {
        'targetId': viewerId,
        'candidate': candidate.toMap(),
        'roomId': roomId
      });
    };

    localStream!.getTracks().forEach((track) {
      pc.addTrack(track, localStream!);
    });

    final offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    
    socket.emit('webrtc-offer', {
      'targetId': viewerId,
      'offer': offer.toMap(),
      'roomId': roomId
    });
  }

  // --- VIEWER SPECIFIC ---

  Future<void> _handleOffer(dynamic data) async {
    final senderId = data['senderId'];
    if (senderId == socket.id) {
      debugPrint('Received webrtc-offer from self, ignoring.');
      return;
    }
    
    final offerData = data['offer'];
    
    final pc = await createPeerConnection(configuration);
    peerConnections[senderId] = pc;

    pc.onIceCandidate = (candidate) {
      socket.emit('webrtc-ice-candidate', {
        'targetId': senderId,
        'candidate': candidate.toMap(),
        'roomId': roomId
      });
    };

    pc.onIceConnectionState = (state) {
      debugPrint('ICE connection state with $senderId: $state');
      if (state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
        isPeerConnected = true;
      } else if (state == RTCIceConnectionState.RTCIceConnectionStateFailed ||
                 state == RTCIceConnectionState.RTCIceConnectionStateDisconnected ||
                 state == RTCIceConnectionState.RTCIceConnectionStateClosed) {
        isPeerConnected = false;
      }
      onRenderUpdated?.call();
    };

    pc.onConnectionState = (state) {
      debugPrint('Connection state with $senderId: $state');
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        isPeerConnected = true;
      } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
                 state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
                 state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        isPeerConnected = false;
      }
      onRenderUpdated?.call();
    };

    pc.onAddStream = (stream) {
      remoteRenderer.srcObject = stream;
      isPeerConnected = true;
      onStreamStarted?.call();
      onRenderUpdated?.call();
    };

    pc.onTrack = (event) async {
      debugPrint('Got remote track: ${event.track.kind}, streams: ${event.streams.length}');
      if (event.track.kind == 'audio') {
        event.track.enabled = true;
      }
      if (event.streams.isNotEmpty) {
        remoteRenderer.srcObject = event.streams[0];
      } else {
        try {
          remoteRenderer.srcObject ??= await createLocalMediaStream('remote_stream_${DateTime.now().millisecondsSinceEpoch}');
          remoteRenderer.srcObject!.addTrack(event.track);
        } catch (e) {
          debugPrint('Failed to add track to remote stream: $e');
        }
      }
      isPeerConnected = true;
      onStreamStarted?.call();
      onRenderUpdated?.call();
    };

    final sdp = offerData['sdp']?.toString() ?? '';
    final type = offerData['type']?.toString() ?? 'offer';
    await pc.setRemoteDescription(RTCSessionDescription(sdp, type));
    
    _hasRemoteDescription[senderId] = true;
    if (_iceCandidateQueue.containsKey(senderId)) {
      for (var cData in _iceCandidateQueue[senderId]!) {
        final cand = cData['candidate']?.toString() ?? '';
        final sdpMid = cData['sdpMid']?.toString();
        final sdpMLineIndex = cData['sdpMLineIndex'] is int 
            ? cData['sdpMLineIndex'] as int 
            : int.tryParse(cData['sdpMLineIndex']?.toString() ?? '');
        await pc.addCandidate(RTCIceCandidate(cand, sdpMid, sdpMLineIndex));
      }
      _iceCandidateQueue.remove(senderId);
    }
    
    final answer = await pc.createAnswer();
    await pc.setLocalDescription(answer);

    socket.emit('webrtc-answer', {
      'targetId': senderId,
      'answer': answer.toMap(),
      'roomId': roomId
    });
  }

  Future<void> _handleAnswer(dynamic data) async {
    if (data == null || data is! Map) return;
    final senderId = data['senderId']?.toString();
    if (senderId == null) return;
    final answerData = data['answer'];
    if (answerData == null || answerData is! Map) return;
    
    final pc = peerConnections[senderId];
    if (pc != null) {
      final sdp = answerData['sdp']?.toString() ?? '';
      final type = answerData['type']?.toString() ?? 'answer';
      await pc.setRemoteDescription(RTCSessionDescription(sdp, type));
      
      _hasRemoteDescription[senderId] = true;
      if (_iceCandidateQueue.containsKey(senderId)) {
        for (var cData in _iceCandidateQueue[senderId]!) {
          final cand = cData['candidate']?.toString() ?? '';
          final sdpMid = cData['sdpMid']?.toString();
          final sdpMLineIndex = cData['sdpMLineIndex'] is int 
              ? cData['sdpMLineIndex'] as int 
              : int.tryParse(cData['sdpMLineIndex']?.toString() ?? '');
          await pc.addCandidate(RTCIceCandidate(cand, sdpMid, sdpMLineIndex));
        }
        _iceCandidateQueue.remove(senderId);
      }
    }
  }

  Future<void> _handleIceCandidate(dynamic data) async {
    if (data == null || data is! Map) return;
    final senderId = data['senderId']?.toString();
    if (senderId == null) return;
    final candidateData = data['candidate'];
    if (candidateData == null || candidateData is! Map) return;
    
    final candidateMap = Map<String, dynamic>.from(candidateData);
    final pc = peerConnections[senderId];
    if (pc != null) {
      if (_hasRemoteDescription[senderId] == true) {
        final cand = candidateMap['candidate']?.toString() ?? '';
        final sdpMid = candidateMap['sdpMid']?.toString();
        final sdpMLineIndex = candidateMap['sdpMLineIndex'] is int 
            ? candidateMap['sdpMLineIndex'] as int 
            : int.tryParse(candidateMap['sdpMLineIndex']?.toString() ?? '');
        await pc.addCandidate(RTCIceCandidate(cand, sdpMid, sdpMLineIndex));
      } else {
        _iceCandidateQueue.putIfAbsent(senderId, () => []);
        _iceCandidateQueue[senderId]!.add(candidateMap);
      }
    } else {
      _iceCandidateQueue.putIfAbsent(senderId, () => []);
      _iceCandidateQueue[senderId]!.add(candidateMap);
    }
  }

  void clearRemoteStream() {
    isPeerConnected = false;
    remoteRenderer.srcObject = null;
    for (var pc in peerConnections.values) {
      try { pc.close(); } catch (_) {}
    }
    peerConnections.clear();
    _iceCandidateQueue.clear();
    _hasRemoteDescription.clear();
    onRenderUpdated?.call();
  }

  void stop() {
    socket.off('webrtc-offer');
    socket.off('webrtc-answer');
    socket.off('webrtc-ice-candidate');
    
    clearRemoteStream();
    localStream?.getTracks().forEach((t) => t.stop());
    localRenderer.dispose();
    remoteRenderer.dispose();
  }
}

