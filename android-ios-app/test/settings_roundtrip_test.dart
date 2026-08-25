// The cross-device round trip.
//
// A settings-set REPLACES the whole category row, so every key this client
// publishes must also be one it can APPLY. When it publishes a key it cannot
// receive, it reads the other device's value, ignores it, and writes its own
// back — and because D1 is the source of truth, that reverts the setting on
// every device. The user sees "I changed it on the web, then my phone
// connected, and it went back to the default".
//
// Each key is probed in isolation, against a fresh container, so one key's
// value cannot mask or break another's. Several candidate values are tried per
// key and it is only reported as broken when NONE survives: a list of channel
// names and a list of pubkeys accept different shapes, and a value rejected for
// being malformed is not the same as a value that was dropped.
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/models/settings.dart';
import 'package:nym_bar/services/api/storage_sync.dart';
import 'package:nym_bar/services/storage/key_value_store.dart';
import 'package:nym_bar/state/nostr_controller.dart';
import 'package:nym_bar/state/settings_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Booleans that are a VIEW of another key rather than state of their own: the
/// scope string is authoritative and the flag is recomputed from it. Probing
/// one without the other makes the pair contradict, and the apply is right to
/// prefer the scope.
const _derivedFrom = <String, String>{
  'readReceiptsEnabled': 'readReceiptsScope',
  'typingIndicatorsEnabled': 'typingIndicatorsScope',
};

/// Shapes to try for a collection-valued key. A channel list, a pubkey list and
/// a language list validate their entries differently.
final _candidates = <Object>[
  'f' * 64, // a well-formed pubkey / event id
  'probe', // a plain channel or geohash name
  'en', // a language tag
];

/// String settings whose value is parsed into an enum or checked against a
/// fixed set, so the probe has to use a REAL alternative — an invented one
/// would be rejected by the apply and read as a bug that isn't there. Every
/// other string setter is an unvalidated pass-through, so an arbitrary
/// non-empty value exercises it honestly.
const _validAlternatives = <String, String>{
  'theme': 'cyber', // NymThemeKey.id
  'colorMode': 'light', // ColorMode.name
  'readReceiptsScope': 'pms', // Settings.indicatorScopes
  'typingIndicatorsScope': 'groups',
  'swipeLeftAction': 'react', // validSwipeActions
  'swipeRightAction': 'zap',
};

/// A string value no default uses, for the pass-through setters.
const _stringProbe = 'probe-value';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final selfPubkey = 'a' * 64;

  Future<(ProviderContainer, KeyValueStore)> freshContainer() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final kv = await KeyValueStore.open();
    return (
      ProviderContainer(overrides: [keyValueStoreProvider.overrideWithValue(kv)]),
      kv
    );
  }

  Map<String, dynamic> flatten(Settings s, KeyValueStore kv) {
    final out = <String, dynamic>{};
    StorageSync.buildSectionPayloads(s, kv: kv, selfPubkey: selfPubkey)
        .forEach((_, fields) => out.addAll(fields));
    return out;
  }

  test('every published settings key survives an inbound apply', () async {
    final (probeContainer, probeKv) = await freshContainer();
    // Start from what this client itself publishes, so every value already has
    // the type and shape the apply guards expect.
    final baseline = flatten(const Settings(), probeKv);
    probeContainer.dispose();

    final broken = <String>[];
    final skipped = <String>[];
    var probed = 0;

    for (final entry in baseline.entries) {
      final key = entry.key;
      final base = entry.value;
      if (key == 'v' || _derivedFrom.containsKey(key)) continue;

      // Values to try for this key. Strings use a real alternative where the
      // value is parsed or validated (see _validAlternatives) and an arbitrary
      // non-empty one elsewhere, since those setters are pass-throughs.
      final tries = <Object>[
        if (base is bool) !base,
        if (base is int) base + 7,
        if (base is String)
          _validAlternatives[key] ??
              (base == _stringProbe ? 'probe-value-2' : _stringProbe),
        if (base is List && base.isEmpty)
          for (final c in _candidates) <dynamic>[c],
        if (base is Map && base.isEmpty)
          for (final c in _candidates) <String, dynamic>{'$c': 1700000000},
        // Keys whose DEFAULT is already non-empty need a mutation derived from
        // it, or they would go unprobed — which is how a clobber hides.
        if (base is List && base.isNotEmpty) base.reversed.toList(),
        if (base is Map && base.isNotEmpty)
          {for (final e in base.entries) e.key: 'probe-${e.value}'},
        if (base == null) _stringProbe,
      ];
      if (tries.isEmpty) {
        skipped.add('$key (${base.runtimeType})');
        continue;
      }
      probed++;

      Object? lastGot;
      var survived = false;
      for (final want in tries) {
        final (container, kv) = await freshContainer();
        try {
          container
              .read(nostrControllerProvider)
              .applySyncedSettingsForTest({...baseline, key: want, 'v': 2});
          // Some apply paths persist through an unawaited future.
          await Future<void>.delayed(const Duration(milliseconds: 20));
          final got = flatten(container.read(settingsProvider), kv)[key];
          lastGot = got;
          if (_holds(want, got)) {
            survived = true;
            break;
          }
        } finally {
          container.dispose();
        }
      }
      if (!survived) broken.add('  $key: sent ${tries.first}, published back $lastGot');
    }

    // Guards against the probe quietly shrinking: if a future change makes
    // values un-probeable, this fails rather than passing vacuously.
    debugPrint('round-trip probed $probed of ${baseline.length} published keys');
    debugPrint('not probed: ${skipped.join(', ')}');
    expect(skipped, isEmpty,
        reason: 'every published key must be probed — an unprobed key is '
            'exactly where a clobber hides');
    expect(probed, greaterThanOrEqualTo(55),
        reason: 'the probe must cover nearly every published key');
    expect(
      broken,
      isEmpty,
      reason: 'these keys are published but never applied, so this device '
          'overwrites every other device with its own value:\n${broken.join('\n')}',
    );
  });
}

/// Collections sync as a union, so growth is fine; losing the value is not.
bool _holds(Object? want, Object? got) {
  if (want is List) return got is List && want.every(got.contains);
  if (want is Map) {
    return got is Map &&
        want.entries.every((e) => got.containsKey(e.key) && got[e.key] == e.value);
  }
  return want == got;
}
