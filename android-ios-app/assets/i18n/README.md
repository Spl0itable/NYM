# Pre-translated interface packs

One `<lang>.json` per language: a flat map of English source string to its
translation, loaded by `LocalizationService._primeFromPack` the moment a
language is selected.

Bundled rather than fetched on purpose. A phone that meshes over Bluetooth with
the network down still has to be able to switch language, and one request per
string — which is what this replaces — meant the interface filled in over tens
of seconds while every user re-paid for translations every user before them had
already paid for.

**Generated, not hand-edited.** They come from the NYM repository, which owns
the translation cache:

```sh
# in the NYM repo
npm run i18n                                          # translate what is missing
npm run i18n:export -- --out ../flutter-app/assets/i18n
```

See ../../docs/TRANSLATIONS.md.
