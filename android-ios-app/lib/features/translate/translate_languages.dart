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
