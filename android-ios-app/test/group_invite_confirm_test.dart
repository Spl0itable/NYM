import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nym_bar/core/theme/nym_colors.dart';
import 'package:nym_bar/core/theme/nym_theme.dart';
import 'package:nym_bar/features/groups/group_invite_confirm.dart';
import 'package:nym_bar/models/group.dart';
import 'package:nym_bar/services/storage/key_value_store.dart';
import 'package:nym_bar/state/settings_provider.dart';

GroupInviteToken _token(String name) => GroupInviteToken(
      groupId: 'a' * 64,
      approver: 'b' * 64,
      epoch: 3,
      name: name,
    );

Future<void> _pumpHost(
    WidgetTester tester, GroupInviteToken token, List<bool> results) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final kv = await KeyValueStore.open();
  final colors = resolveNymColors(
    theme: NymThemeKey.bitchat,
    brightness: Brightness.dark,
    solidUi: true,
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [keyValueStoreProvider.overrideWithValue(kv)],
      child: MaterialApp(
        theme: buildNymThemeData(colors),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async =>
                  results.add(await confirmGroupInviteJoin(context, token)),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  group('groupInviteConfirmMessage', () {
    test('names the group from the invite', () {
      expect(groupInviteConfirmMessage(_token('My Group')),
          'Join "My Group"? A join request will be sent to a group member.');
    });

    test('sanitizes control characters and caps the length', () {
      final msg = groupInviteConfirmMessage(_token('Bad\nName\t${'x' * 60}'));
      expect(msg, contains('"Bad Name '));
      expect(msg, isNot(contains('\n')));
      expect(groupInviteDisplayName(_token('y' * 60)).length, 40);
    });

    test('falls back to generic copy when the invite has no name', () {
      expect(groupInviteConfirmMessage(_token('  ')),
          'Join this group? A join request will be sent to a group member.');
    });
  });

  testWidgets('confirming resolves true', (tester) async {
    final results = <bool>[];
    await _pumpHost(tester, _token('My Group'), results);
    expect(find.textContaining('Join "My Group"?'), findsOneWidget);
    await tester.tap(find.text('JOIN'));
    await tester.pumpAndSettle();
    expect(results, [true]);
  });

  testWidgets('cancelling resolves false', (tester) async {
    final results = <bool>[];
    await _pumpHost(tester, _token('My Group'), results);
    await tester.tap(find.text('CANCEL'));
    await tester.pumpAndSettle();
    expect(results, [false]);
  });

  group('every invite entry point confirms before joining', () {
    for (final path in [
      'lib/features/messages/format/message_content.dart',
      'lib/features/pms/new_pm_modal.dart',
    ]) {
      test(path, () {
        final src = File(path).readAsStringSync();
        final confirm = src.indexOf('confirmGroupInviteJoin(context');
        expect(confirm, greaterThan(-1));
        expect(
            src.indexOf('joinGroupViaInvite(', confirm), greaterThan(confirm));
        expect(RegExp(r'\.joinGroupViaInvite\(').allMatches(src).length, 1);
      });
    }

    test('deep links route through the confirm dialog', () {
      final app = File('lib/app.dart').readAsStringSync();
      expect(app.contains('confirmInvite: _confirmGroupInvite'), isTrue);
      expect(app.contains('confirmGroupInviteJoin(navContext, token)'), isTrue);
    });
  });
}
