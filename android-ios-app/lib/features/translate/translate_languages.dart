// FORMATTING: the tables below are dense on purpose, mirroring the web
// client's source. `dart format` explodes them to one entry per line, and
// the `// dart format off` directive cannot protect them because it needs
// language version >= 3.7 while this package is on ^3.6.0 (legacy
// formatter, which ignores the directive). Keep this file OUT of
// repo-wide format passes.
/// Google-Translate language code → display name (translate.js
/// `NYM_TRANSLATE_LANGUAGES` / `NYM_TRANSLATE_LANG_NAMES`). Trimmed to the
/// resolver the inline translation label needs (`_languageName`).
const Map<String, String> kTranslateLanguageNames = {
  'af': 'Afrikaans', 'sq': 'Albanian', 'am': 'Amharic', 'ar': 'Arabic',
  'hy': 'Armenian', 'as': 'Assamese', 'ay': 'Aymara', 'az': 'Azerbaijani',
  'bm': 'Bambara', 'eu': 'Basque', 'be': 'Belarusian', 'bn': 'Bengali',
  'bho': 'Bhojpuri', 'bs': 'Bosnian', 'bg': 'Bulgarian', 'ca': 'Catalan',
  'ceb': 'Cebuano', 'ny': 'Chichewa', 'zh': 'Chinese (Simplified)',
  'zh-tw': 'Chinese (Traditional)', 'zh-cn': 'Chinese (Simplified)',
  'co': 'Corsican', 'hr': 'Croatian', 'cs': 'Czech', 'da': 'Danish',
  'dv': 'Dhivehi', 'doi': 'Dogri', 'nl': 'Dutch', 'en': 'English',
  'eo': 'Esperanto', 'et': 'Estonian', 'ee': 'Ewe', 'fil': 'Filipino',
  'fi': 'Finnish', 'fr': 'French', 'fy': 'Frisian', 'gl': 'Galician',
  'ka': 'Georgian', 'de': 'German', 'el': 'Greek', 'gn': 'Guarani',
  'gu': 'Gujarati', 'ht': 'Haitian Creole', 'ha': 'Hausa', 'haw': 'Hawaiian',
  'he': 'Hebrew', 'iw': 'Hebrew', 'hi': 'Hindi', 'hmn': 'Hmong',
  'hu': 'Hungarian', 'is': 'Icelandic', 'ig': 'Igbo', 'ilo': 'Ilocano',
  'id': 'Indonesian', 'ga': 'Irish', 'it': 'Italian', 'ja': 'Japanese',
  'jv': 'Javanese', 'jw': 'Javanese', 'kn': 'Kannada', 'kk': 'Kazakh',
  'km': 'Khmer', 'rw': 'Kinyarwanda', 'gom': 'Konkani', 'ko': 'Korean',
  'kri': 'Krio', 'ku': 'Kurdish (Kurmanji)', 'ckb': 'Kurdish (Sorani)',
  'ky': 'Kyrgyz', 'lo': 'Lao', 'la': 'Latin', 'lv': 'Latvian', 'ln': 'Lingala',
  'lt': 'Lithuanian', 'lg': 'Luganda', 'lb': 'Luxembourgish', 'mk': 'Macedonian',
  'mai': 'Maithili', 'mg': 'Malagasy', 'ms': 'Malay', 'ml': 'Malayalam',
  'mt': 'Maltese', 'mi': 'Maori', 'mr': 'Marathi',
  'mni-mtei': 'Meiteilon (Manipuri)', 'lus': 'Mizo', 'mn': 'Mongolian',
  'my': 'Myanmar (Burmese)', 'ne': 'Nepali', 'no': 'Norwegian',
  'or': 'Odia (Oriya)', 'om': 'Oromo', 'ps': 'Pashto', 'fa': 'Persian',
  'pl': 'Polish', 'pt': 'Portuguese', 'pa': 'Punjabi', 'qu': 'Quechua',
  'ro': 'Romanian', 'ru': 'Russian', 'sm': 'Samoan', 'sa': 'Sanskrit',
  'gd': 'Scots Gaelic', 'nso': 'Sepedi', 'sr': 'Serbian', 'st': 'Sesotho',
  'sn': 'Shona', 'sd': 'Sindhi', 'si': 'Sinhala', 'sk': 'Slovak',
  'sl': 'Slovenian', 'so': 'Somali', 'es': 'Spanish', 'su': 'Sundanese',
  'sw': 'Swahili', 'sv': 'Swedish', 'tg': 'Tajik', 'ta': 'Tamil', 'tt': 'Tatar',
  'te': 'Telugu', 'th': 'Thai', 'ti': 'Tigrinya', 'ts': 'Tsonga',
  'tr': 'Turkish', 'tk': 'Turkmen', 'ak': 'Twi', 'uk': 'Ukrainian',
  'ur': 'Urdu', 'ug': 'Uyghur', 'uz': 'Uzbek', 'vi': 'Vietnamese',
  'cy': 'Welsh', 'xh': 'Xhosa', 'yi': 'Yiddish', 'yo': 'Yoruba', 'zu': 'Zulu',
};

/// What speakers call their own language (CLDR endonyms, mirroring the web
/// client's `NYM_TRANSLATE_LANG_NATIVE`). Only codes whose endonym differs from
/// the English name are listed; the rest fall back to [kTranslateLanguageNames].
const Map<String, String> kTranslateLanguageNative = {
  'sq': "shqip", 'am': "አማርኛ", 'ar': "العربية", 'hy': "հայերեն",
  'as': "অসমীয়া", 'az': "azərbaycan", 'bm': "bamanakan", 'eu': "euskara",
  'be': "беларуская", 'bn': "বাংলা", 'bho': "भोजपुरी", 'bs': "bosanski",
  'bg': "български", 'ca': "català", 'ny': "Nyanja", 'zh': "中文",
  'zh-tw': "中文（台灣）", 'hr': "hrvatski", 'cs': "čeština", 'da': "dansk",
  'dv': "Divehi", 'doi': "डोगरी", 'nl': "Nederlands", 'et': "eesti",
  'ee': "eʋegbe", 'fi': "suomi", 'fr': "français", 'fy': "Frysk",
  'gl': "galego", 'ka': "ქართული", 'de': "Deutsch", 'el': "Ελληνικά",
  'gu': "ગુજરાતી", 'haw': "ʻŌlelo Hawaiʻi", 'he': "עברית", 'hi': "हिन्दी",
  'hu': "magyar", 'is': "íslenska", 'ilo': "Iloko", 'id': "Indonesia",
  'ga': "Gaeilge", 'it': "italiano", 'ja': "日本語", 'jv': "Jawa",
  'kn': "ಕನ್ನಡ", 'kk': "қазақ тілі", 'km': "ខ្មែរ", 'rw': "Ikinyarwanda",
  'gom': "कोंकणी", 'ko': "한국어", 'ku': "kurdî (kurmancî)",
  'ckb': "کوردیی ناوەندی", 'ky': "кыргызча", 'lo': "ລາວ", 'lv': "latviešu",
  'ln': "lingála", 'lt': "lietuvių", 'lb': "Lëtzebuergesch",
  'mk': "македонски", 'mai': "मैथिली", 'ms': "Melayu", 'ml': "മലയാളം",
  'mt': "Malti", 'mi': "Māori", 'mr': "मराठी",
  'mni-mtei': "মৈতৈলোন্ (মীতৈ ময়েক)", 'mn': "монгол", 'my': "မြန်မာ",
  'ne': "नेपाली", 'no': "norsk", 'or': "ଓଡ଼ିଆ", 'om': "Oromoo", 'ps': "پښتو",
  'fa': "فارسی", 'pl': "polski", 'pt': "português", 'pa': "ਪੰਜਾਬੀ",
  'qu': "Runasimi", 'ro': "română", 'ru': "русский", 'sa': "संस्कृत भाषा",
  'gd': "Gàidhlig", 'nso': "Sesotho sa Leboa", 'sr': "српски",
  'sn': "chiShona", 'sd': "سنڌي", 'si': "සිංහල", 'sk': "slovenčina",
  'sl': "slovenščina", 'so': "Soomaali", 'es': "español", 'su': "Basa Sunda",
  'sw': "Kiswahili", 'sv': "svenska", 'tg': "тоҷикӣ", 'ta': "தமிழ்",
  'tt': "татар", 'te': "తెలుగు", 'th': "ไทย", 'ti': "ትግርኛ", 'tr': "Türkçe",
  'tk': "türkmen dili", 'ak': "Akan", 'uk': "українська", 'ur': "اردو",
  'ug': "ئۇيغۇرچە", 'uz': "o‘zbek", 'vi': "Tiếng Việt", 'cy': "Cymraeg",
  'xh': "IsiXhosa", 'yi': "ייִדיש", 'yo': "Èdè Yorùbá", 'zu': "isiZulu",
};

/// What a speaker of the language calls it, falling back to the English name.
/// A picker labelled only in English is unusable to the very people looking for
/// their own language in it.
String languageNative(String? code) {
  if (code == null || code.isEmpty) return '';
  final key = code.toLowerCase();
  final alias = const {'zh-cn': 'zh', 'iw': 'he', 'jw': 'jv'}[key] ?? key;
  return kTranslateLanguageNative[alias] ??
      kTranslateLanguageNames[alias] ??
      code;
}

/// The English name, but only when it adds something to the endonym.
String languageSubtitle(String? code) {
  final native = languageNative(code);
  final english = languageName(code);
  return native == english ? '' : english;
}

/// Everything a search over the language list should match.
String languageSearchKey(String code, String name) =>
    '$name ${languageNative(code)}'.toLowerCase();

/// Resolves a language code to its display name (translate.js `_languageName`),
/// falling back to the raw code.
String languageName(String? code) {
  if (code == null || code.isEmpty) return '';
  return kTranslateLanguageNames[code.toLowerCase()] ?? code;
}

/// Languages sorted alphabetically by name — used by the language picker prompt
/// (translate.js `_promptTranslateLanguage`).
List<MapEntry<String, String>> sortedTranslateLanguages() {
  final list = kTranslateLanguageNames.entries
      // drop the duplicate alias codes so each language appears once
      .where((e) => !{'zh-cn', 'iw', 'jw'}.contains(e.key))
      .toList()
    ..sort((a, b) => a.value.compareTo(b.value));
  return list;
}

/// Languages with [favorites] pinned to the top (in fav-list order), the rest
/// alphabetical — the in-composer translate dropdown order (translate.js
/// `_sortedTranslateLanguages`, lines 112-122). The prompt keeps plain alpha.
List<MapEntry<String, String>> sortedTranslateLanguagesWithFavorites(
    List<String> favorites) {
  final all = sortedTranslateLanguages();
  if (favorites.isEmpty) return all;
  final byCode = {for (final e in all) e.key: e};
  final favList = <MapEntry<String, String>>[
    for (final code in favorites)
      if (byCode.containsKey(code)) byCode[code]!,
  ];
  final favSet = favorites.toSet();
  final rest = all.where((e) => !favSet.contains(e.key)).toList();
  return [...favList, ...rest];
}

/// localStorage key for the translate-dropdown favorites (translate.js:96/107).
const String kTranslateFavoritesKey = 'nym_translate_favorites';
