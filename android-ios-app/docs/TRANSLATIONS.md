# Interface translations

The app's interface is available in 132 languages. This document covers where
those translations come from and how to refresh them, because the pipeline that
produces them lives in the NYM repository, not this one.

## How it works

Every string the app shows in a non-English language reaches it one of two ways:

1. **A bundled pack** — `assets/i18n/<lang>.json`, a flat map of English source
   string to its translation, read the moment a language is selected. This is
   the fast path and it answers almost everything.
2. **On demand**, through the translation proxy, one request per string, cached
   on the device. This is the fallback for anything the pack does not carry: a
   string added since the last export, or one the extractor could not see.

Before the packs existed, (2) was the only path — picking a language meant
re-translating around 1500 strings on the device, filling in over tens of
seconds, with every user paying again for work every user before them had
already paid for.

The packs are **bundled rather than fetched**, deliberately. A phone that meshes
over Bluetooth with the network down still has to be able to switch language,
and this was the one part of the interface that needed a server to work at all.
Flutter reads an asset only when it is asked for, so carrying every language
costs bundle size (~4-6 MB), not memory.

`LocalizationService._primeFromPack` does the reading. A missing or malformed
pack is not an error — it leaves the on-demand path exactly as it was — and an
on-device translation is never overwritten by one from a pack, since the
device's copy is either from the pack already or newer than it.

## Refreshing them

**The pipeline lives in the NYM repository.** This is a Dart project with no
Node toolchain, so there is no `npm run i18n` to run here:

```sh
# in the NYM repo, with this repository checked out beside it
npm run i18n            # translate anything not already cached
npm run i18n -- --list  # coverage report, no network
npm run i18n:export -- --out ../flutter-app/assets/i18n
```

Then commit the changed files under `assets/i18n/` here.

The translation cache is committed in the NYM repo, so a language is paid for
once by whoever runs the sync rather than once per user who selects it. The
export step is free — it only reshapes what the cache already holds.

If this repository is not a sibling of the NYM checkout, point the sync at its
catalog with `NYM_FLUTTER_CATALOG=/path/to/app_strings_catalog.dart`.

## Adding a string

`lib/features/i18n/app_strings_catalog.dart` is what makes a string eligible for
pre-translation — the sync reads that file directly from this repository. A
string passed to `tr()` but absent from the catalog still works and is still
translated on demand; it just never makes it into a pack, so it arrives slowly
instead of instantly.

The NYM repo's `android-ios-app/` directory is a read-only release mirror of
this one and is deliberately **not** used as the source, so a stale mirror can
never cause packs to be built from a previous release's copy of the catalog.
