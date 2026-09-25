import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nym_bar/core/theme/nym_colors.dart';
import 'package:nym_bar/core/theme/nym_theme.dart';
import 'package:nym_bar/core/utils/secret_screen.dart';
import 'package:nym_bar/services/storage/key_value_store.dart';
import 'package:nym_bar/state/settings_provider.dart';
import 'package:nym_bar/widgets/common/app_dialog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<bool> secureCalls;
  String? clipboard;

  setUp(() {
    secureCalls = [];
    clipboard = null;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SecretScreen.channel, (call) async {
      if (call.method == 'secure') secureCalls.add(call.arguments as bool);
      return null;
    });
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboard = (call.arguments as Map)['text'] as String?;
      } else if (call.method == 'Clipboard.getData') {
        return {'text': clipboard};
      }
      return null;
    });
  });

  testWidgets('the screen is protected while a secret is showing',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await tester.pumpWidget(const MaterialApp(
        home: Column(children: [SecretGuard(), SecretGuard()])));
    expect(SecretScreen.held, isTrue);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    expect(SecretScreen.held, isFalse);
    expect(secureCalls, [true, false]);
    debugDefaultTargetPlatformOverride = null;
  });

  test('a copied secret is cleared from the clipboard later', () async {
    await SecretScreen.copy('nsec1secret',
        life: const Duration(milliseconds: 10));
    expect(clipboard, 'nsec1secret');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(clipboard, '');
  });

  test('something copied since is left alone', () async {
    await SecretScreen.copy('nsec1secret',
        life: const Duration(milliseconds: 10));
    clipboard = 'hello';
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(clipboard, 'hello');
  });

  testWidgets('a secret shown in a dialog is guarded', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final kv = KeyValueStore(await SharedPreferences.getInstance());
    await tester.pumpWidget(ProviderScope(
      overrides: [keyValueStoreProvider.overrideWithValue(kv)],
      child: MaterialApp(
        theme: buildNymThemeData(resolveNymColors(
          theme: NymThemeKey.bitchat,
          brightness: Brightness.dark,
          solidUi: true,
        )),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showAppAlert(context, 'save this',
                  copyValue: 'nympq1code', secret: true),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(SecretGuard), findsOneWidget);
    await tester.tap(find.text('Copy'));
    await tester.pump();
    expect(clipboard, 'nympq1code');
    await tester.pump(SecretScreen.clipboardLife + const Duration(seconds: 1));
    expect(clipboard, '');
  });
}
