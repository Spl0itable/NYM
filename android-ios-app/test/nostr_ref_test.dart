/// NIP-19 references: what the formatter marks up, what decodes, and what the
/// timestamp popup offers to copy.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/core/crypto/bech32_codec.dart';
import 'package:nym_bar/features/messages/format/nym_format.dart';

const _id = 'a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4';
const _pubkey =
    'f00dbabef00dbabef00dbabef00dbabef00dbabef00dbabef00dbabef00dbabe';

List<InlineNode> _inlines(String text) {
  final blocks = NymFormat.format(text, const FormatContext());
  final out = <InlineNode>[];
  for (final b in blocks) {
    if (b is ParagraphBlock) out.addAll(b.inlines);
  }
  return out;
}

List<NostrRefNode> _refs(String text) =>
    _inlines(text).whereType<NostrRefNode>().toList();

void main() {
  group('decoding', () {
    test('a bare hex id is an event reference', () {
      final r = decodeNostrRef(_id)!;
      expect(r.kind, NostrRefKind.event);
      expect(r.id, _id);
    });

    test('an uppercase hex id is normalised', () {
      expect(decodeNostrRef(_id.toUpperCase())!.id, _id);
    });

    test('a note carries its event id', () {
      expect(decodeNostrRef(encodeNote(_id))!.id, _id);
    });

    test('an npub is a profile reference', () {
      final r = decodeNostrRef(encodeNpub(_pubkey))!;
      expect(r.kind, NostrRefKind.profile);
      expect(r.pubkey, _pubkey);
    });

    test('an nevent round-trips id, author and relay hints', () {
      final token = encodeNevent(_id,
          author: _pubkey, relays: ['wss://a.example', 'wss://b.example']);
      final r = decodeNostrRef(token)!;
      expect(r.kind, NostrRefKind.event);
      expect(r.id, _id);
      expect(r.pubkey, _pubkey);
      expect(r.relays, ['wss://a.example', 'wss://b.example']);
    });

    test('an nevent takes at most three relay hints', () {
      final token = encodeNevent(_id, relays: [
        'wss://a.example',
        'wss://b.example',
        'wss://c.example',
        'wss://d.example',
      ]);
      expect(decodeNostrRef(token)!.relays.length, 3);
    });

    test('the nostr: scheme is stripped before decoding', () {
      expect(decodeNostrRef('nostr:${encodeNote(_id)}')!.id, _id);
    });

    test('an nsec is never a reference', () {
      final nsec = encodeNsecBytes(Uint8List(32)..fillRange(0, 32, 7));
      expect(decodeNostrRef(nsec), isNull);
    });

    test('garbage and empties decode to null', () {
      expect(decodeNostrRef('nevent1notrealatall'), isNull);
      expect(decodeNostrRef(''), isNull);
      expect(decodeNostrRef('   '), isNull);
      expect(decodeNostrRef('hello world'), isNull);
    });

    test('a non-hex id has no nevent', () {
      expect(encodeNevent('not-an-id'), '');
    });

    test('references key on what they point at', () {
      expect(decodeNostrRef(_id)!.key, 'e:$_id');
      expect(decodeNostrRef(encodeNpub(_pubkey))!.key, 'p:$_pubkey');
    });
  });

  group('formatter', () {
    test('a nostr: entity becomes a reference node', () {
      final refs = _refs('look at nostr:${encodeNote(_id)} ok');
      expect(refs.length, 1);
      expect(refs.single.token, encodeNote(_id));
      expect(refs.single.raw, isFalse);
    });

    test('a bare note1 is a reference too', () {
      expect(_refs('bare ${encodeNote(_id)} here').length, 1);
    });

    test('an npub alone still formats', () {
      expect(_refs(encodeNpub(_pubkey)).length, 1);
    });

    test('an entity inside a URL path stays part of the link', () {
      final text = 'https://njump.me/${encodeNote(_id)}';
      expect(_refs(text), isEmpty);
      expect(_inlines(text).whereType<LinkNode>().length, 1);
    });

    test('a bare 64-hex id is marked, but kept raw', () {
      final refs = _refs('id $_id end');
      expect(refs.length, 1);
      expect(refs.single.token, _id);
      expect(refs.single.raw, isTrue,
          reason: '64 hex characters are not always an event id');
    });

    test('hex inside a URL query is left alone', () {
      expect(_refs('https://x.com/?h=$_id'), isEmpty);
    });

    test('unrelated prose produces no references', () {
      expect(_refs('plain words with no references at all'), isEmpty);
    });

    test('several references in one message are all found', () {
      final text = '${encodeNote(_id)} and ${encodeNpub(_pubkey)}';
      expect(_refs(text).length, 2);
    });
  });
}
