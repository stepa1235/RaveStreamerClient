import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:flutter/foundation.dart';
import 'dart:io';

class WebRTCManager {
  final IO.Socket socket;
  final String roomId;
  final bool Function() isHostResolver;
  
  MediaStream? localStream;
  RTCVideoRenderer localRenderer = RTCVideoRenderer();
  RTCVideoRenderer remoteRenderer = RTCVideoRenderer();
  
  // Map of viewer Socket ID -> RTCPeerConnection
  final Map<String, RTCPeerConnection> peerConnections = {};
  final Map<String, List<Map<String, dynamic>>> _iceCandidateQueue = {};
  final Map<String, bool> _hasRemoteDescription = {};

  final Map<String, dynamic> configuration = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
      {'urls': 'stun:stun.yandex.ru:3478'},
    ]
  };

  Function()? onStreamStarted;
  Function()? onStreamStopped;
  Function(String)? onError;

  WebRTCManager({
    required this.socket, 
    required this.roomId, 
    required this.isHostResolver
  });

  Future<void> initialize() async {
    await localRenderer.initialize();
    await remoteRenderer.initialize();

    if (Platform.isAndroid || Platform.isIOS) {
      try {
        Helper.setSpeakerphoneOn(true);
      } catch (e) {
        debugPrint('Failed to set speakerphone: $e');
      }
    }

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
        'audio': true, // Try to capture audio
        'video': {
          'deviceId': {'exact': sourceId},
          'mandatory': {
            'minFrameRate': fps.toString(),
            'minWidth': width.toString(),
            'minHeight': height.toString(),
          }
        }
      };

      localStream = await navigator.mediaDevices.getDisplayMedia(mediaConstraints);
      localRenderer.srcObject = localStream;
      
      socket.emit('start-stream', {'roomId': roomId});
      onStreamStarted?.call();
      
      // Stop stream if user stops sharing from OS UI
      localStream?.getVideoTracks().first.onEnded = () {
        stopScreenShare();
      };
      
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
    try {
      if (isHostResolver() && localStream != null) return; // Host shouldn't receive offers if natively streaming
      
      final senderId = data['senderId'];
      final offerData = data['offer'];
      
      final pc = await createPeerConnection(configuration);
      peerConnections[senderId] = pc;
      _iceCandidateQueue.putIfAbsent(senderId, () => []);
      _hasRemoteDescription[senderId] = false;

      pc.onIceCandidate = (candidate) {
        socket.emit('webrtc-ice-candidate', {
          'targetId': senderId,
          'candidate': candidate.toMap(),
          'roomId': roomId
        });
      };

      pc.onAddStream = (stream) {
        remoteRenderer.srcObject = stream;
        if (Platform.isAndroid || Platform.isIOS) {
          try { Helper.setSpeakerphoneOn(true); } catch (_) {}
        }
        onStreamStarted?.call();
      };

      pc.onTrack = (event) async {
        debugPrint('Got remote track: ${event.track.kind}');
        if (event.streams.isNotEmpty) {
          remoteRenderer.srcObject = event.streams[0];
        }
        if (Platform.isAndroid || Platform.isIOS) {
          try { Helper.setSpeakerphoneOn(true); } catch (_) {}
        }
        onStreamStarted?.call();
      };


      await pc.setRemoteDescription(RTCSessionDescription(offerData['sdp'], offerData['type']));
      _hasRemoteDescription[senderId] = true;
      
      final queued = _iceCandidateQueue[senderId];
      if (queued != null) {
        for (var cData in queued) {
          await pc.addCandidate(RTCIceCandidate(
            cData['candidate'],
            cData['sdpMid'],
            cData['sdpMLineIndex']
          ));
        }
        _iceCandidateQueue.remove(senderId);
      }
      
      final answer = await pc.createAnswer({
        'mandatory': {
          'OfferToReceiveAudio': true,
          'OfferToReceiveVideo': true,
        },
      });
      await pc.setLocalDescription(answer);

      socket.emit('webrtc-answer', {
        'targetId': senderId,
        'answer': answer.toMap(),
        'roomId': roomId
      });
    } catch (e) {
      print('Error handling WebRTC offer: $e');
    }
  }

  Future<void> _handleAnswer(dynamic data) async {
    try {
      final senderId = data['senderId'];
      final answerData = data['answer'];
      
      final pc = peerConnections[senderId];
      if (pc != null) {
        await pc.setRemoteDescription(RTCSessionDescription(answerData['sdp'], answerData['type']));
      }
    } catch (e) {
      print('Error handling WebRTC answer: $e');
    }
  }

  Future<void> _handleIceCandidate(dynamic data) async {
    try {
      final senderId = data['senderId'];
      final candidateData = data['candidate'] as Map<String, dynamic>;
      
      final pc = peerConnections[senderId];
      if (pc != null) {
        if (_hasRemoteDescription[senderId] == true) {
          await pc.addCandidate(RTCIceCandidate(
            candidateData['candidate'],
            candidateData['sdpMid'],
            candidateData['sdpMLineIndex']
          ));
        } else {
          _iceCandidateQueue.putIfAbsent(senderId, () => []).add(candidateData);
        }
      } else {
        _iceCandidateQueue.putIfAbsent(senderId, () => []).add(candidateData);
      }
    } catch (e) {
      print('Error handling WebRTC ICE candidate: $e');
    }
  }

  void stop() {
    socket.off('webrtc-offer');
    socket.off('webrtc-answer');
    socket.off('webrtc-ice-candidate');
    
    localStream?.getTracks().forEach((t) => t.stop());
    localRenderer.dispose();
    remoteRenderer.dispose();
    
    for (var pc in peerConnections.values) {
      pc.close();
    }
    peerConnections.clear();
  }
}


