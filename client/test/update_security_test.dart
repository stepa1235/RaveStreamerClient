import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:luna_updates/luna_updates.dart';

const _url =
    'https://github.com/stepa1235/RaveStreamerClient/releases/download/v1.2.0/Luna-Windows.zip';
const _hash =
    'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';

LunaUpdate? release({
  String url = _url,
  String? digest = 'sha256:$_hash',
  String current = '1.1.1',
  bool prerelease = false,
}) {
  return LunaUpdate.fromRelease(
    {
      'tag_name': 'v1.2.0',
      'prerelease': prerelease,
      'assets': [
        {
          'name': 'Luna-Windows.zip',
          'state': 'uploaded',
          'size': 3,
          'digest': digest,
          'browser_download_url': url,
        },
      ],
    },
    current,
    UpdatePlatform.windows,
  );
}

void main() {
  test(
    'only newer stable releases with the exact platform asset are offered',
    () {
      expect(release()?.version, '1.2.0');
      expect(release(current: '1.2.0+42'), isNull);
      expect(release(prerelease: true), isNull);
      expect(() => release(digest: null), throwsFormatException);
      for (final url in [
        _url.replaceFirst('https:', 'http:'),
        _url.replaceFirst('github.com', 'github.com.example'),
        _url.replaceFirst('v1.2.0', 'v1.1.0'),
        _url.replaceFirst('Luna-Windows.zip', 'other.zip'),
      ]) {
        expect(() => release(url: url), throwsFormatException);
      }
    },
  );

  test(
    'download checks redirect origin, size, and SHA-256 before installation',
    () async {
      final directory = await Directory.systemTemp.createTemp('luna-test-');
      addTearDown(() => directory.delete(recursive: true));
      final destination = File('${directory.path}/update.zip');
      final update = release()!;
      Future<void> download(String payload, {String? redirect}) async {
        final client = MockClient((request) async {
          expect(request.followRedirects, isFalse);
          if (redirect != null && request.url.host == 'github.com') {
            return http.Response('', 302, headers: {'location': redirect});
          }
          return http.Response(payload, 200);
        });
        try {
          await downloadLunaUpdate(update, destination, (_) {}, client: client);
        } finally {
          client.close();
        }
      }

      await download(
        'abc',
        redirect: 'https://release-assets.githubusercontent.com/test',
      );
      expect(await destination.readAsString(), 'abc');
      await expectLater(download('bad'), throwsFormatException);
      expect(await destination.exists(), isFalse);
      await expectLater(download('ab'), throwsA(isA<HttpException>()));
      expect(await destination.exists(), isFalse);
      await expectLater(
        download('abc', redirect: 'https://example.com/test'),
        throwsA(isA<HttpException>()),
      );
      expect(await destination.exists(), isFalse);
    },
  );
}
