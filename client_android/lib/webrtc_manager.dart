import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:flutter/foundation.dart';

class WebRTCManager {
  final IO.Socket socket;
  final String roomId;
  final bool isHost;
  
  MediaStream? localStream;
  RTCVideoRenderer localRenderer = RTCVideoRenderer();
  RTCVideoRenderer remoteRenderer = RTCVideoRenderer();
  
  // Map of viewer Socket ID -> RTCPeerConnection
  final Map<String, RTCPeerConnection> peerConnections = {};

  final Map<String, dynamic> configuration = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
    ]
  };

  Function()? onStreamStarted;
  Function()? onStreamStopped;
  Function(String)? onError;

  WebRTCManager({
    required this.socket, 
    required this.roomId, 
    required this.isHost
  });

  Future<void> initialize() async {
    await localRenderer.initialize();
    await remoteRenderer.initialize();

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
    if (!isHost) return;

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
    if (!isHost) return;
    
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
    if (!isHost || localStream == null) return;

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

  Future<void> _handleOffer(data) async {
    try {
      if (isHost && localStream != null) return; // Host shouldn't receive offers if natively streaming
      
      final senderId = data['senderId'];
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

      pc.onTrack = (event) {
        if (event.streams.isNotEmpty) {
          remoteRenderer.srcObject = event.streams[0];
        }
        if (event.track.kind == 'video') {
          onStreamStarted?.call();
        }
      };

      await pc.setRemoteDescription(RTCSessionDescription(offerData['sdp'], offerData['type']));
      
      final answer = await pc.createAnswer({});
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

  Future<void> _handleAnswer(data) async {
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

  Future<void> _handleIceCandidate(data) async {
    try {
      final senderId = data['senderId'];
      final candidateData = data['candidate'];
      
      final pc = peerConnections[senderId];
      if (pc != null && candidateData != null) {
        await pc.addCandidate(RTCIceCandidate(
          candidateData['candidate'],
          candidateData['sdpMid'],
          candidateData['sdpMLineIndex']
        ));
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
