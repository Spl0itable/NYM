// The pre-translated UI packs bundled at assets/i18n/<lang>.json.
//
// Picking a language used to re-translate the whole interface on the device,
// one request per string — around 1500 of them — so the UI filled in over tens
// of seconds and every user paid for the same work again. The finished
// translations now ship with the app, and this reads one.
//
// What these pin is that the pack is an OPTIMISATION and never a dependency: a
// missing or malformed pack has to leave the old runtime path exactly as it
// was, and an on-device translation must never be overwritten by an older one
// from the pack. That matters most for a language whose pack has not been
// exported yet — the app must simply behave as it did before packs existed.
import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nym_bar/features/i18n/localization_service.dart';
import 'package:nym_bar/services/api/api_client.dart';
import 'package:nym_bar/services/storage/key_value_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<KeyValueStore> _store() async {
  SharedPreferences.setMockInitialValues({});
  return KeyValueStore(await SharedPreferences.getInstance());
}

/// A pack loader serving [packs] keyed by language code, recording what was
/// asked for. A code with no entry throws, exactly as `rootBundle.loadString`
/// does for an asset that is not bundled.
({Future<String> Function(String) load, List<String> asked}) _loader(
    Map<String, Object> packs) {
  final asked = <String>[];
  return (
    load: (key) async {
      asked.add(key);
      final code = key.split('/').last.replaceAll('.json', '');
      final pack = packs[code];
      if (pack == null) throw Exception('Unable to load asset: $key');
      return pack is String ? pack : jsonEncode(pack);
    },
    asked: asked,
  );
}

/// An ApiClient whose translate calls always fail, so anything that ends up
/// translated came from the pack and nowhere else.
ApiClient _deadProxy() => ApiClient(
      client: MockClient((_) async => http.Response('{"error":"down"}', 502)),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late LocalizationService svc;

  setUp(() async {
    svc = LocalizationService.instance;
    svc.setLanguage('');
    svc.resetPackStateForTest();
    svc.configure(kv: await _store(), language: '', apiClient: _deadProxy());
  });

  tearDown(() {
    svc.setLanguage('');
    svc.packLoader = rootBundle.loadString;
  });

  test('a bundled pack translates without a single proxy call', () async {
    final l = _loader({
      'es': {'Settings': 'Ajustes', 'Language': 'Idioma'},
    });
    svc.packLoader = l.load;
    svc.setLanguage('es');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(l.asked, ['assets/i18n/es.json']);
    expect(svc.translate('Settings'), 'Ajustes');
    expect(svc.translate('Language'), 'Idioma');
  });

  test('a string the pack lacks still falls through to the old path', () async {
    svc.packLoader = _loader({
      'es': {'Settings': 'Ajustes'},
    }).load;
    svc.setLanguage('es');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(svc.translate('Settings'), 'Ajustes');
    // Not in the pack, and the proxy is dead: English, exactly as before.
    expect(svc.translate('Some brand new string'), 'Some brand new string');
  });

  test('a language with no pack exported yet is not an error', () async {
    // The state every language is in before the first export run.
    svc.packLoader = _loader({}).load;
    svc.setLanguage('es');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(svc.translate('Settings'), 'Settings');
    expect(svc.isActive, isTrue);
  });

  test('a malformed pack is not an error', () async {
    svc.packLoader = _loader({'es': 'not json at all'}).load;
    svc.setLanguage('es');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(svc.translate('Settings'), 'Settings');
  });

  test('a pack that is not an object is not an error', () async {
    svc.packLoader = _loader({'es': '["a","b"]'}).load;
    svc.setLanguage('es');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(svc.translate('Settings'), 'Settings');
  });

  test('non-string values in a pack are ignored', () async {
    svc.packLoader = _loader({
      'es': {'Settings': 'Ajustes', 'Language': 42, 'Close': ''},
    }).load;
    svc.setLanguage('es');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(svc.translate('Settings'), 'Ajustes');
    expect(svc.translate('Language'), 'Language');
    expect(svc.translate('Close'), 'Close');
  });

  test('an on-device translation is not overwritten by the pack', () async {
    // The device's copy is either from the pack already or newer than it.
    final kv = await _store();
    kv.setString('nym_ui_i18n_es', jsonEncode({'Settings': 'On-device'}));
    svc.setLanguage('');
    svc.resetPackStateForTest();
    svc.configure(kv: kv, language: '', apiClient: _deadProxy());
    svc.packLoader = _loader({
      'es': {'Settings': 'From-pack'},
    }).load;
    svc.setLanguage('es');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(svc.translate('Settings'), 'On-device');
  });

  test('the pack is read once per language per session', () async {
    final l = _loader({
      'es': {'Settings': 'Ajustes'},
    });
    svc.packLoader = l.load;
    svc.setLanguage('es');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    svc.setLanguage('');
    svc.setLanguage('es');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(l.asked, hasLength(1));
  });

  test('English reads nothing', () async {
    final l = _loader({'en': <String, String>{}});
    svc.packLoader = l.load;
    svc.setLanguage('en');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(l.asked, isEmpty);
  });

  test('a pack that lands after a language switch is discarded', () async {
    // Otherwise Spanish strings would appear in a French UI.
    svc.packLoader = (key) async {
      final spanish = key.endsWith('es.json');
      if (spanish) await Future<void>.delayed(const Duration(milliseconds: 60));
      return jsonEncode({'Settings': spanish ? 'Ajustes' : 'Paramètres'});
    };
    svc.setLanguage('es');
    svc.setLanguage('fr');
    await Future<void>.delayed(const Duration(milliseconds: 160));
    expect(svc.translate('Settings'), 'Paramètres');
  });

  test('a pack with non-ASCII text survives the decode', () async {
    // Most of the 132 languages are not Latin-1, so a decode bug here would be
    // invisible in English and wrong everywhere else.
    svc.packLoader = _loader({
      'ja': {'Settings': '設定', 'Close': '閉じる'},
    }).load;
    svc.setLanguage('ja');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(svc.translate('Settings'), '設定');
    expect(svc.translate('Close'), '閉じる');
  });
}
