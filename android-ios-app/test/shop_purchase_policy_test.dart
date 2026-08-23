// The iOS build doesn't sell flair — it shows the catalogue and states where a
// purchase is made. These pin the two halves of that: the platform gate, and
// the card dropping its BUY / GIFT actions when the gate is on.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/features/i18n/app_strings_catalog.dart';
import 'package:nym_bar/features/nymbot/bot_credits_modal.dart';
import 'package:nym_bar/features/shop/shop_purchase_policy.dart';

void main() {
  test('purchases stay enabled off iOS', () {
    // The suite runs on the host VM, so this is the Android/desktop path — the
    // one that must keep its in-app Lightning invoice untouched.
    expect(shopPurchasesDisabled, isFalse);
  });

  testWidgets('the notice is a statement, not a call to action', (tester) async {
    // Guards the rule in shop_purchase_policy.dart: the copy must not be wired
    // to a tap target, because a button or link pointing at an outside
    // purchasing mechanism is exactly what Apple's 3.1.1 prohibits.
    const notice =
        'Flair cannot be purchased in this app. Items are bought from the '
        'Nymchat web app in your browser. Anything you already own works here '
        'as usual.';
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: Text(notice)),
    ));
    expect(find.text(notice), findsOneWidget);
    expect(find.byType(TextButton), findsNothing);
    expect(find.byType(InkWell), findsNothing);
    expect(find.byType(GestureDetector), findsNothing);
  });

  group('Nymbot credits', () {
    test('follow the same gate as flair', () {
      // Credits are the same kind of digital good; the two answers must not be
      // able to drift apart by accident.
      expect(botCreditPurchasesDisabled, shopPurchasesDisabled);
      expect(botCreditPurchasesDisabled, isFalse);
    });

    test('every string the disabled sheet shows is in the sweep catalog', () {
      for (final s in kBotCreditsDisabledStrings) {
        expect(kAppStringsCatalog, contains(s), reason: s);
      }
    });

    testWidgets('the notice is a statement, not a call to action',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: Text(kBotCreditsBuyNotice)),
      ));
      expect(find.text(kBotCreditsBuyNotice), findsOneWidget);
      expect(find.byType(TextButton), findsNothing);
      expect(find.byType(InkWell), findsNothing);
      expect(find.byType(GestureDetector), findsNothing);
    });
  });
}
