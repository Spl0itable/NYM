// Tests for the calls + notifications feature pure logic. No real WebRTC,
// media, permissions or network — only the factored-out pure functions.

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/features/calls/call_signaling.dart';
import 'package:nym_bar/features/notifications/notification_sounds.dart';

void main() {
  group('glare / initiator decision (lexicographic pubkey compare)', () {
    test('smaller pubkey is the offerer', () {
      expect(isOfferer(selfPubkey: 'aaaa', peerPubkey: 'bbbb'), isTrue);
      expect(isOfferer(selfPubkey: 'bbbb', peerPubkey: 'aaaa'), isFalse);
    });

    test('hex pubkeys compare lexicographically like calls.js `<`', () {
      const a = '00ff00';
      const b = '00ff01';
      expect(isOfferer(selfPubkey: a, peerPubkey: b), isTrue);
      expect(isOfferer(selfPubkey: b, peerPubkey: a), isFalse);
    });

    test('equal pubkeys are never the offerer (no self-offer)', () {
      expect(isOfferer(selfPubkey: 'abcd', peerPubkey: 'abcd'), isFalse);
    });

    test('decision is symmetric — exactly one side offers', () {
      const a = 'f00dcafe';
      const b = '0badf00d';
      final aOffers = isOfferer(selfPubkey: a, peerPubkey: b);
      final bOffers = isOfferer(selfPubkey: b, peerPubkey: a);
      expect(aOffers != bOffers, isTrue);
    });
  });

  group('signaling payload builders match calls.js shapes', () {
    test('invite', () {
      final p = CallSignal.invite(
        callId: 'call-1',
        kind: CallKind.video,
        isGroup: true,
        groupId: 'g1',
        members: ['a', 'b', 'c'],
      );
      expect(p, {
        'type': 'invite',
        'callId': 'call-1',
        'kind': 'video',
        'isGroup': true,
        'groupId': 'g1',
        'members': ['a', 'b', 'c'],
      });
    });

    test('invite audio uses kind "audio"', () {
      final p = CallSignal.invite(
        callId: 'call-2',
        kind: CallKind.audio,
        isGroup: false,
        groupId: null,
        members: ['a', 'b'],
      );
      expect(p['kind'], 'audio');
      expect(p['isGroup'], false);
      expect(p['groupId'], isNull);
    });

    test('accept / cancel / hangup', () {
      expect(CallSignal.accept('c'), {'type': 'accept', 'callId': 'c'});
      expect(CallSignal.cancel('c'), {'type': 'cancel', 'callId': 'c'});
      expect(CallSignal.hangup('c'), {'type': 'hangup', 'callId': 'c'});
    });

    test('reject carries the reason', () {
      expect(CallSignal.reject('c', 'busy'),
          {'type': 'reject', 'callId': 'c', 'reason': 'busy'});
      expect(CallSignal.reject('c', 'declined')['reason'], 'declined');
      expect(CallSignal.reject('c', 'media')['reason'], 'media');
    });

    test('offer / answer nest sdp as { type, sdp }', () {
      final offer = CallSignal.offer(
          callId: 'c', sdpType: 'offer', sdp: 'v=0...');
      expect(offer, {
        'type': 'offer',
        'callId': 'c',
        'sdp': {'type': 'offer', 'sdp': 'v=0...'},
      });
      final answer = CallSignal.answer(
          callId: 'c', sdpType: 'answer', sdp: 'v=0...');
      expect(answer['type'], 'answer');
      expect((answer['sdp'] as Map)['type'], 'answer');
    });

    test('ice nests the candidate fields', () {
      final ice = CallSignal.ice(
        callId: 'c',
        candidate: 'candidate:1 ...',
        sdpMid: '0',
        sdpMLineIndex: 0,
      );
      expect(ice['type'], 'ice');
      expect(ice['callId'], 'c');
      expect((ice['candidate'] as Map)['candidate'], 'candidate:1 ...');
      expect((ice['candidate'] as Map)['sdpMid'], '0');
      expect((ice['candidate'] as Map)['sdpMLineIndex'], 0);
    });

    test('chat slices text to 2000 chars and carries mid', () {
      final long = 'x' * 2500;
      final p = CallSignal.chat(callId: 'c', text: long, mid: 'm1');
      expect(p['type'], 'chat');
      expect((p['text'] as String).length, 2000);
      expect(p['mid'], 'm1');
    });

    test('share / reaction', () {
      expect(CallSignal.share(callId: 'c', on: true),
          {'type': 'share', 'callId': 'c', 'on': true});
      expect(CallSignal.reaction(callId: 'c', emoji: '🔥'),
          {'type': 'reaction', 'callId': 'c', 'emoji': '🔥'});
    });
  });

  group('ring-timeout logic transitions ringing -> ended', () {
    test('the configured ring timeout is 45 seconds (calls.js)', () {
      expect(kCallRingTimeout, const Duration(seconds: 45));
    });

    test('a fake timer fires the cancel/end after the timeout', () {
      fakeAsync((async) {
        var phase = CallPhase.ringing;
        var sentCancel = false;
        // Mimic _begin's ringTimeout: cancel + end if still outgoing.
        Timer(kCallRingTimeout, () {
          if (phase == CallPhase.ringing) {
            sentCancel = true;
            phase = CallPhase.ended;
          }
        });
        // Just before the deadline: still ringing.
        async.elapse(const Duration(seconds: 44));
        expect(phase, CallPhase.ringing);
        expect(sentCancel, isFalse);
        // After the deadline: ended.
        async.elapse(const Duration(seconds: 2));
        expect(phase, CallPhase.ended);
        expect(sentCancel, isTrue);
      });
    });

    test('answering before the timeout prevents the transition', () {
      fakeAsync((async) {
        var phase = CallPhase.ringing;
        final t = Timer(kCallRingTimeout, () {
          if (phase == CallPhase.ringing) phase = CallPhase.ended;
        });
        // Peer answers at 10s -> connecting, cancel the ring timer.
        async.elapse(const Duration(seconds: 10));
        phase = CallPhase.connecting;
        t.cancel();
        async.elapse(const Duration(seconds: 60));
        expect(phase, CallPhase.connecting);
      });
    });
  });

  group('acceptCalls preference gate', () {
    test('disabled never rings', () {
      expect(
          shouldRingForInvite(acceptCalls: 'disabled', isFriend: true), isFalse);
      expect(
          shouldRingForInvite(acceptCalls: 'disabled', isFriend: false), isFalse);
    });
    test('friends rings only for friends', () {
      expect(
          shouldRingForInvite(acceptCalls: 'friends', isFriend: true), isTrue);
      expect(
          shouldRingForInvite(acceptCalls: 'friends', isFriend: false), isFalse);
    });
    test('enabled always rings', () {
      expect(
          shouldRingForInvite(acceptCalls: 'enabled', isFriend: false), isTrue);
    });
  });

  group('sound selection maps setting -> tone descriptor', () {
    test('classic beep', () {
      final d = resolveSound('beep');
      expect(d, isNotNull);
      expect(d!.wave, SoundWave.sine);
      expect(d.notes.first.f, 800);
    });

    test('ICQ Uh-Oh (two-note sawtooth glide)', () {
      final d = resolveSound('uhoh');
      expect(d, isNotNull);
      expect(d!.wave, SoundWave.sawtooth);
      expect(d.notes.length, 2);
      expect(d.notes.first.f, 587);
      expect(d.notes.first.f2, 523);
    });

    test('MSN Alert', () {
      final d = resolveSound('msnding');
      expect(d, isNotNull);
      expect(d!.notes.length, 2);
      expect(d.notes.last.f, 1318.51);
    });

    test('legacy aliases icq -> uhoh, msn -> msnding', () {
      expect(resolveSound('icq'), same(resolveSound('uhoh')));
      expect(resolveSound('msn'), same(resolveSound('msnding')));
    });

    test('silent plays nothing', () {
      expect(resolveSound('none'), isNull);
      expect(soundIsAudible('none'), isFalse);
    });

    test('unknown sound is treated as silent', () {
      expect(resolveSound('does-not-exist'), isNull);
      expect(soundIsAudible('does-not-exist'), isFalse);
    });

    test('audible sounds report audible', () {
      expect(soundIsAudible('beep'), isTrue);
      expect(soundIsAudible('uhoh'), isTrue);
      expect(soundIsAudible('msnding'), isTrue);
    });
  });

  group('WAV synthesis produces a valid buffer', () {
    test('beep renders a non-empty RIFF/WAVE buffer', () {
      final wav = renderSoundWav(kNotificationSounds['beep']!);
      expect(wav.length, greaterThan(44)); // header + samples
      // RIFF....WAVE header
      expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
      expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
    });

    test('silent selection renders nothing via the service contract', () {
      // resolveSound('none') == null, so a player must skip — assert here.
      expect(resolveSound('none'), isNull);
    });
  });
}
