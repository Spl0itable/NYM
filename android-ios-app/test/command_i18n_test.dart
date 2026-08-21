import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nym_bar/features/commands/command_i18n.dart';
import 'package:nym_bar/features/commands/command_registry.dart';
import 'package:nym_bar/features/i18n/localization_service.dart';
import 'package:nym_bar/services/api/api_client.dart';
import 'package:nym_bar/services/storage/key_value_store.dart';

// A stand-in translator with real Spanish for the phrases the command
// vocabularies ask for; anything else comes back unchanged (which the alias
// builder treats as "not translated").
const Map<String, String> _es = {
  'help': 'ayuda',
  'join': 'unirse',
  'private message': 'mensaje privado',
  'who': 'quién',
  'clear': 'borrar',
  'add member': 'agregar miembro',
  'transfer owner': 'transferir propietario',
  'bold': 'negrita',
  'ask': 'preguntar',
  'joke': 'chiste',
  'model': 'modelo',
  'image': 'imagen',
};

Future<void> _useSpanish() async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final kv = await KeyValueStore.open();
  final svc = LocalizationService.instance;
  svc.setLanguage('en');
  final mock = MockClient((req) async {
    final text = (jsonDecode(req.body)['text'] ?? '').toString();
    return http.Response(
      jsonEncode({
        'translatedText': _es[text] ?? text,
        'detectedLanguage': 'en',
      }),
      200,
      headers: {'content-type': 'application/json'},
    );
  });
  svc.configure(
    kv: kv,
    language: 'es',
    apiClient: ApiClient(client: mock, baseUrl: 'https://h/api/proxy'),
  );
  svc.prime(commandSourcePhrases());
  // Debounced flush + mock round-trips.
  await Future<void>.delayed(const Duration(milliseconds: 800));
}

void main() {
  tearDown(() => LocalizationService.instance.setLanguage('en'));

  group('command vocabulary (English)', () {
    test('canonical tokens cover both / and ? vocabularies', () {
      final tokens = canonicalCommandTokens();
      expect(tokens, contains('/join'));
      expect(tokens, contains('?ask'));
      expect(tokens, contains('?image'), reason: 'PM-only commands count too');
      expect(tokens.where((t) => t.length <= 2), isEmpty,
          reason: 'single-letter shortcuts stay English');
      expect(tokens.toSet().length, tokens.length, reason: 'no duplicates');
    });

    test('proper nouns are never translated', () {
      for (final token in ['?btc', '?git', '?nostr', '?8ball']) {
        expect(commandSourcePhrase(token), isNull);
      }
      expect(commandSourcePhrases(), isNot(contains('btc')));
    });

    test('with no language selected everything stays canonical', () {
      expect(localizedCommandToken('/join'), '/join');
      expect(resolveCommandToken('/join'), '/join');
      expect(canonicalizeCommandInput('/join #nym'), '/join #nym');
      expect(commandAliasHint('/join #nym'), isNull);
      expect(localizeCommandTokensIn('type /join'), 'type /join');
    });

    test('slug folds a phrase into one typeable token', () {
      expect(commandSlug('mensaje privado'), 'mensajeprivado');
      expect(commandSlug('  Añadir Miembro '), 'añadirmiembro');
      expect(commandDeaccent('quién'), 'quien');
    });
  });

  group('command vocabulary (Spanish)', () {
    test('display names, aliases and canonicalization', () async {
      await _useSpanish();

      expect(localizedCommandToken('/join'), '/unirse');
      expect(localizedCommandToken('/pm'), '/mensajeprivado');
      expect(localizedCommandToken('?joke'), '?chiste');
      expect(localizedCommandToken('?btc'), '?btc');
      expect(localizedCommandToken('?git'), '?git');

      // Localized names resolve, and so do the originals.
      expect(resolveCommandToken('/unirse'), '/join');
      expect(resolveCommandToken('/UNIRSE'), '/join');
      expect(resolveCommandToken('/join'), '/join');
      expect(resolveCommandToken('/j'), '/join');
      expect(resolveCommandToken('/quién'), '/who');
      expect(resolveCommandToken('/quien'), '/who',
          reason: 'typing without accents still works');
      expect(resolveCommandToken('/mensaje'), '/pm',
          reason: 'first word of a multi-word translation');
      expect(resolveCommandToken('/mensajeprivado'), '/pm');
      expect(resolveCommandToken('/nonsense'), isNull);

      expect(canonicalizeCommandInput('?imagen un gato'), '?image un gato');
      expect(canonicalizeCommandInput('?image un gato'), '?image un gato');
      expect(canonicalizeCommandInput('hola mundo'), 'hola mundo');
      expect(commandAliasHint('?imagen un gato'),
          {'typed': '?imagen', 'canonical': '?image'});
      expect(commandAliasHint('?image un gato'), isNull);
    });

    test('rendered text shows the names the app accepts', () async {
      await _useSpanish();
      expect(localizeCommandTokensIn('Escribe ?joke o /join #nym'),
          'Escribe ?chiste o /unirse #nym');
      expect(localizeCommandTokensIn('https://nymchat.app/join'),
          'https://nymchat.app/join',
          reason: 'a url path is not a command');
    });

    test('palette and help show the localized name with English shortcuts',
        () async {
      await _useSpanish();
      final join = kCommandSpecs.firstWhere((s) => s.name == '/join');
      expect(localizedCommandDisplay(join), '/unirse, /j');
      final rows = buildLocalizedBotPaletteRows('?chi');
      expect(rows.map((r) => r.command), contains('?chiste'));
      expect(buildLocalizedBotPaletteRows('?jo').map((r) => r.command),
          contains('?chiste'),
          reason: 'the English name still filters');
    });
  });
}
