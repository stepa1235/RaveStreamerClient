import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:luna_room/luna_room.dart';

void main() {
  test('invite links preserve the room and reject a different server', () {
    const origin = 'http://luna.lumigrid.ru:3000';
    final invite = RoomInvite('movie_night', 'a' * 48);
    final link = invite.toLink(origin);
    expect(link.query, isEmpty);
    expect(RoomInvite.parse(link.toString(), origin)?.roomId, invite.roomId);
    expect(RoomInvite.parse(link.toString(), origin)?.token, invite.token);
    expect(RoomInvite.parse(link.toString(), 'https://other.example'), isNull);
    final nativeLink = Uri(
      scheme: 'luna',
      host: 'invite',
      fragment: Uri(
        queryParameters: {
          'server': origin,
          'room': invite.roomId,
          'token': invite.token,
        },
      ).query,
    );
    expect(
      RoomInvite.parse(nativeLink.toString(), origin)?.token,
      invite.token,
    );
  });

  testWidgets(
    'room tools update viewer readiness and hide host-only controls from guests',
    (tester) async {
      final state = ValueNotifier<Map<String, dynamic>>({
        'autoPause': false,
        'viewers': [
          {
            'id': 'me',
            'username': 'Me',
            'readiness': 'loading',
            'isHost': false,
          },
        ],
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RoomTools(
              russian: false,
              roomId: 'movie',
              server: 'https://example.test',
              socketId: () => 'me',
              state: state,
              send: (_, _) {},
              request: (_, _) async => null,
              diagnose: () async => '10 ms',
              bookmark: () {},
              canBookmark: () => false,
            ),
          ),
        ),
      );
      expect(find.text('Loading'), findsOneWidget);
      expect(find.text('Pause when a viewer buffers'), findsNothing);
      state.value = {
        'autoPause': true,
        'viewers': [
          {'id': 'me', 'username': 'Me', 'readiness': 'ready', 'isHost': true},
        ],
      };
      await tester.pump();
      expect(find.text('Ready'), findsOneWidget);
      expect(find.text('Pause when a viewer buffers'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    },
  );
}
