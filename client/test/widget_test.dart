import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:client/screens/connection_page.dart';

void main() {
  testWidgets('Settings preview is applied only when saved', (tester) async {
    final saved = <(String, String, double)>[];
    await tester.pumpWidget(MaterialApp(
      home: ConnectionPage(
        locale: 'ru',
        onLocaleChange: (_) {},
        themeName: 'Dark',
        onThemeChange: (_) {},
        initialUsername: 'Tester',
        initialServerUrl: 'http://luna.lumigrid.ru:3000',
        onSavedConnection: (_, _) {},
        chatFontSize: 12,
        onChatFontSizeChange: (_) {},
        clientId: 'settings-test',
        onPreferencesSaved: (language, theme, size) {
          saved.add((language, theme, size));
        },
      ),
    ));

    Future<void> openSettings() async {
      await tester.tap(find.text('Настройки'));
      await tester.pumpAndSettle();
      expect(find.text('Настройки Luna'), findsOneWidget);
    }

    await openSettings();
    await tester.tap(find.text('English'));
    await tester.pumpAndSettle();
    expect(find.text('Luna settings'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(saved, isEmpty);

    await openSettings();
    await tester.tap(find.text('English'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Neon Cyan'));
    await tester.pumpAndSettle();
    final slider = tester.widget<Slider>(find.byType(Slider));
    slider.onChanged!(18);
    await tester.pumpAndSettle();
    final preview = tester.widget<Text>(
      find.text('This is how a chat message will look.'),
    );
    expect(preview.style?.fontSize, 18);
    expect(saved, isEmpty);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(saved, [('en', 'Neon Cyan', 18.0)]);
  });
}
