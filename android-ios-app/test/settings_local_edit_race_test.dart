// A settings change made while the boot restore is still in flight.
//
// The D1 apply is deliberately unconditional — it heals local KV drift — but
// the boot read can take many seconds (it retries with backoff), and the user
// can change a setting in that window. Applying the older stored blob then
// overwrites the change they just made, and the pending publish afterwards
// carries the OVERWRITTEN value, so it is lost on this device and every other:
// "I changed it, it showed, I reloaded, it was gone".
//
// A local edit awaiting publish has to win over the stored blob it predates.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/services/storage/key_value_store.dart';
import 'package:nym_bar/state/nostr_controller.dart';
import 'package:nym_bar/state/settings_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('an inbound apply does not undo a local change still awaiting publish',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final kv = await KeyValueStore.open();
    final container = ProviderContainer(
      overrides: [keyValueStoreProvider.overrideWithValue(kv)],
    );
    addTearDown(container.dispose);

    final settings = container.read(settingsProvider.notifier);
    final controller = container.read(nostrControllerProvider);

    // The user changes two settings while the boot restore is still running.
    settings.setSwipeLeftAction('zap');
    settings.setColumnsWallpaper(true);
    controller.markSettingsDirtyForTest();

    // The boot read finally lands, carrying the values from BEFORE the change.
    controller.applySyncedSettingsForTest(<String, dynamic>{
      'v': 2,
      'swipeLeftAction': 'quote',
      'columnsWallpaper': false,
    });
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final after = container.read(settingsProvider);
    expect(after.swipeLeftAction, 'zap',
        reason: 'the stored blob predates the local change and must not win');
    expect(after.columnsWallpaper, isTrue,
        reason: 'the stored blob predates the local change and must not win');
  });

  test('an inbound apply still heals local drift when nothing is pending',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final kv = await KeyValueStore.open();
    final container = ProviderContainer(
      overrides: [keyValueStoreProvider.overrideWithValue(kv)],
    );
    addTearDown(container.dispose);

    // No local edit outstanding, so the stored blob is authoritative — this is
    // the whole point of the unconditional apply and must keep working.
    container.read(nostrControllerProvider).applySyncedSettingsForTest(
      <String, dynamic>{'v': 2, 'swipeLeftAction': 'zap', 'columnsWallpaper': true},
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final after = container.read(settingsProvider);
    expect(after.swipeLeftAction, 'zap');
    expect(after.columnsWallpaper, isTrue);
  });
}
