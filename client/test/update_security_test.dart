import 'package:flutter_test/flutter_test.dart';
import 'package:client/core/services/update_service.dart';

void main() {
  test('updates accept only HTTPS releases from Luna repository', () {
    expect(
      isTrustedUpdateUrl(
        'https://github.com/stepa1235/RaveStreamerClient/releases/download/v1.2.0/Luna-Windows.zip',
      ),
      isTrue,
    );
    for (final url in [
      'http://github.com/stepa1235/RaveStreamerClient/releases/download/v1/Luna.zip',
      'https://github.com.evil.example/stepa1235/RaveStreamerClient/releases/download/v1/Luna.zip',
      'https://evil.example/Luna.zip',
      'https://github.com/other/repo/releases/download/v1/Luna.zip',
      'https://user@github.com/stepa1235/RaveStreamerClient/releases/download/v1/Luna.zip',
      'https://github.com:444/stepa1235/RaveStreamerClient/releases/download/v1/Luna.zip',
      'file:///C:/Luna.zip',
    ]) {
      expect(isTrustedUpdateUrl(url), isFalse, reason: url);
    }
  });
}
