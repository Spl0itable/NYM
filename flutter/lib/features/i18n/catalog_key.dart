import 'dart:convert';

String i18nCatalogHash(Iterable<String> strings) {
  final list = strings.toSet().toList()..sort();
  var h = 0x811c9dc5;
  for (final b in utf8.encode(list.join('\n'))) {
    h = h ^ b;
    h = (h * 0x193 + (h & 0xff) * 0x1000000) % 0x100000000;
  }
  return h.toRadixString(16).padLeft(8, '0');
}

String i18nCacheKey(String hash, int? build) =>
    'c$hash${build == null ? '' : '.b$build'}';
