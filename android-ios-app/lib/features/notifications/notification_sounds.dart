// notification_sounds.dart - Synthesized notification tones, ported 1:1 from
// `../js/modules/notifications.js` (`NOTIFICATION_SOUNDS` + `playSound`).
//
// The PWA builds each sound at runtime with the Web Audio API. Here we mirror
// the same note tables and render them to a 16-bit mono PCM WAV buffer that the
// platform can play. The descriptor table + selection logic are pure so they
// can be unit-tested without an audio device.

import 'dart:math';
import 'dart:typed_data';

/// One note in a sound sequence — same field names as notifications.js:
/// f (Hz), d (seconds), optional f2 (glide target), gap (silence after),
/// chord (simultaneous freqs), g (gain override), a (attack ramp),
/// h (hold time), noise (bandpass white noise at f), q (noise resonance).
class SoundNote {
  const SoundNote({
    this.f,
    this.d = 0.15,
    this.f2,
    this.gap = 0,
    this.chord,
    this.g,
    this.a,
    this.h,
    this.noise = false,
    this.q,
  });

  final double? f;
  final double d;
  final double? f2;
  final double gap;
  final List<double>? chord;
  final double? g;
  final double? a;
  final double? h;
  final bool noise;
  final double? q;
}

/// Oscillator waveform (notifications.js `sound.wave`).
enum SoundWave { sine, square, sawtooth, triangle }

/// A full sound descriptor (notifications.js `NOTIFICATION_SOUNDS[type]`).
class SoundDescriptor {
  const SoundDescriptor({
    required this.wave,
    required this.gain,
    required this.notes,
  });

  final SoundWave wave;
  final double gain;
  final List<SoundNote> notes;

  /// Total duration in seconds (sum of d + gap), used to size the buffer.
  double get totalDuration =>
      notes.fold(0.0, (acc, n) => acc + n.d + n.gap);
}

/// The complete sound table, verbatim from notifications.js. Keys match
/// `settings.sound` values. `'none'` is intentionally absent (Silent).
const Map<String, SoundDescriptor> kNotificationSounds = {
  'beep': SoundDescriptor(
    wave: SoundWave.sine,
    gain: 0.1,
    notes: [SoundNote(f: 800, d: 0.15)],
  ),
  'low': SoundDescriptor(
    wave: SoundWave.sine,
    gain: 0.15,
    notes: [SoundNote(f: 600, d: 0.15)],
  ),
  'high': SoundDescriptor(
    wave: SoundWave.sine,
    gain: 0.1,
    notes: [SoundNote(f: 1000, d: 0.15)],
  ),
  'uhoh': SoundDescriptor(
    wave: SoundWave.sawtooth,
    gain: 0.08,
    notes: [
      SoundNote(f: 587, f2: 523, d: 0.16, gap: 0.08),
      SoundNote(f: 494, f2: 392, d: 0.28),
    ],
  ),
  'msnding': SoundDescriptor(
    wave: SoundWave.sine,
    gain: 0.12,
    notes: [SoundNote(f: 880, d: 0.1), SoundNote(f: 1318.51, d: 0.45)],
  ),
  'nudge': SoundDescriptor(
    wave: SoundWave.sawtooth,
    gain: 0.1,
    notes: [
      SoundNote(f: 130, f2: 90, d: 0.15),
      SoundNote(f: 130, f2: 90, d: 0.15),
      SoundNote(f: 130, f2: 90, d: 0.15),
    ],
  ),
  'nokia': SoundDescriptor(
    wave: SoundWave.square,
    gain: 0.05,
    notes: [
      SoundNote(f: 1396.91, d: 0.07, gap: 0.07),
      SoundNote(f: 1396.91, d: 0.07, gap: 0.07),
      SoundNote(f: 1396.91, d: 0.07, gap: 0.21),
      SoundNote(f: 1396.91, d: 0.21, gap: 0.07),
      SoundNote(f: 1396.91, d: 0.21, gap: 0.21),
      SoundNote(f: 1396.91, d: 0.07, gap: 0.07),
      SoundNote(f: 1396.91, d: 0.07, gap: 0.07),
      SoundNote(f: 1396.91, d: 0.07),
    ],
  ),
  'nokiatune': SoundDescriptor(
    wave: SoundWave.square,
    gain: 0.05,
    notes: [
      SoundNote(f: 1318.51, d: 0.13),
      SoundNote(f: 1174.66, d: 0.13),
      SoundNote(f: 739.99, d: 0.26),
      SoundNote(f: 830.61, d: 0.26),
      SoundNote(f: 1108.73, d: 0.13),
      SoundNote(f: 987.77, d: 0.13),
      SoundNote(f: 587.33, d: 0.26),
      SoundNote(f: 659.25, d: 0.26),
      SoundNote(f: 987.77, d: 0.13),
      SoundNote(f: 880.00, d: 0.13),
      SoundNote(f: 554.37, d: 0.26),
      SoundNote(f: 659.25, d: 0.26),
      SoundNote(f: 880.00, d: 0.65),
    ],
  ),
  'dialup': SoundDescriptor(
    wave: SoundWave.sine,
    gain: 0.06,
    notes: [
      SoundNote(chord: [350, 440], d: 0.4, gap: 0.05),
      SoundNote(chord: [770, 1209], d: 0.09, gap: 0.04),
      SoundNote(chord: [852, 1336], d: 0.09, gap: 0.04),
      SoundNote(chord: [697, 1477], d: 0.09, gap: 0.25),
      SoundNote(f: 2225, d: 0.35, gap: 0.05),
      SoundNote(f: 1270, d: 0.06),
      SoundNote(f: 2225, d: 0.06),
      SoundNote(f: 1270, d: 0.06),
      SoundNote(f: 2225, d: 0.06),
      SoundNote(f: 1270, d: 0.06),
      SoundNote(f: 2225, d: 0.06),
      SoundNote(chord: [1270, 2225], d: 0.4),
    ],
  ),
  'tetris': SoundDescriptor(
    wave: SoundWave.square,
    gain: 0.06,
    notes: [
      SoundNote(f: 659.25, d: 0.2),
      SoundNote(f: 493.88, d: 0.1),
      SoundNote(f: 523.25, d: 0.1),
      SoundNote(f: 587.33, d: 0.2),
      SoundNote(f: 523.25, d: 0.1),
      SoundNote(f: 493.88, d: 0.1),
      SoundNote(f: 440.00, d: 0.2),
      SoundNote(f: 440.00, d: 0.1),
      SoundNote(f: 523.25, d: 0.1),
      SoundNote(f: 659.25, d: 0.2),
      SoundNote(f: 587.33, d: 0.1),
      SoundNote(f: 523.25, d: 0.1),
      SoundNote(f: 493.88, d: 0.3),
      SoundNote(f: 523.25, d: 0.1),
      SoundNote(f: 587.33, d: 0.2),
      SoundNote(f: 659.25, d: 0.2),
      SoundNote(f: 523.25, d: 0.2),
      SoundNote(f: 440.00, d: 0.2),
      SoundNote(f: 440.00, d: 0.4),
    ],
  ),
  'chirp': SoundDescriptor(
    wave: SoundWave.sine,
    gain: 0.1,
    notes: [
      SoundNote(f: 900, f2: 2200, d: 0.08, gap: 0.06),
      SoundNote(f: 900, f2: 2200, d: 0.08),
    ],
  ),
  'coin': SoundDescriptor(
    wave: SoundWave.square,
    gain: 0.06,
    notes: [SoundNote(f: 987.77, d: 0.08), SoundNote(f: 1318.51, d: 0.65)],
  ),
  'powerup': SoundDescriptor(
    wave: SoundWave.square,
    gain: 0.06,
    notes: [
      SoundNote(f: 522.7, d: 0.033), SoundNote(f: 391.1, d: 0.033),
      SoundNote(f: 522.7, d: 0.033), SoundNote(f: 658.0, d: 0.033),
      SoundNote(f: 782.2, d: 0.033), SoundNote(f: 1045.4, d: 0.033),
      SoundNote(f: 782.2, d: 0.033), SoundNote(f: 414.3, d: 0.033),
      SoundNote(f: 522.7, d: 0.033), SoundNote(f: 621.4, d: 0.033),
      SoundNote(f: 828.6, d: 0.033), SoundNote(f: 621.4, d: 0.033),
      SoundNote(f: 828.6, d: 0.033), SoundNote(f: 1045.4, d: 0.033),
      SoundNote(f: 1242.9, d: 0.033), SoundNote(f: 1645.0, d: 0.033),
      SoundNote(f: 1242.9, d: 0.033), SoundNote(f: 466.1, d: 0.033),
      SoundNote(f: 585.7, d: 0.033), SoundNote(f: 694.8, d: 0.033),
      SoundNote(f: 932.2, d: 0.033), SoundNote(f: 694.8, d: 0.033),
      SoundNote(f: 932.2, d: 0.033), SoundNote(f: 1165.2, d: 0.033),
      SoundNote(f: 1381.0, d: 0.033), SoundNote(f: 1864.3, d: 0.033),
      SoundNote(f: 1381.0, d: 0.15),
    ],
  ),
  'pokeheal': SoundDescriptor(
    wave: SoundWave.square,
    gain: 0.06,
    notes: [
      SoundNote(f: 985.5, d: 0.45),
      SoundNote(f: 985.5, d: 0.45),
      SoundNote(f: 985.5, d: 0.23),
      SoundNote(f: 829.6, d: 0.23),
      SoundNote(f: 1310.7, d: 0.9),
    ],
  ),
  'f1': SoundDescriptor(
    wave: SoundWave.sine,
    gain: 0.14,
    notes: [
      SoundNote(f: 1044, d: 0.12, a: 0.11, g: 0.06),
      SoundNote(f: 781, d: 0.09, h: 0.05, g: 0.14),
      SoundNote(f: 1174, d: 0.09, h: 0.05, g: 0.12),
      SoundNote(f: 985, d: 0.1, h: 0.06, g: 0.11),
    ],
  ),
  'oneup': SoundDescriptor(
    wave: SoundWave.square,
    gain: 0.06,
    notes: [
      SoundNote(f: 659.25, d: 0.13),
      SoundNote(f: 783.99, d: 0.13),
      SoundNote(f: 1318.51, d: 0.13),
      SoundNote(f: 1046.50, d: 0.13),
      SoundNote(f: 1174.66, d: 0.13),
      SoundNote(f: 1567.98, d: 0.4),
    ],
  ),
  'secret': SoundDescriptor(
    wave: SoundWave.square,
    gain: 0.06,
    notes: [
      SoundNote(f: 783.99, d: 0.11),
      SoundNote(f: 739.99, d: 0.11),
      SoundNote(f: 622.25, d: 0.11),
      SoundNote(f: 440.00, d: 0.11),
      SoundNote(f: 415.30, d: 0.11),
      SoundNote(f: 659.25, d: 0.11),
      SoundNote(f: 830.61, d: 0.11),
      SoundNote(f: 1046.50, d: 0.4),
    ],
  ),
  'gameboy': SoundDescriptor(
    wave: SoundWave.square,
    gain: 0.06,
    notes: [SoundNote(f: 1046.50, d: 0.1), SoundNote(f: 2093.00, d: 0.5)],
  ),
};

/// Legacy aliases (notifications.js `playSound`: `{ icq:'uhoh', msn:'msnding' }`).
const Map<String, String> kLegacySoundAliases = {
  'icq': 'uhoh',
  'msn': 'msnding',
};

/// The incoming-call ringtone beep — a single 480 Hz sine note at gain 0.07
/// rendered for 0.4 s, verbatim from calls.js `_startRingtone.playBeep`
/// (`o.frequency.value = 480; g.gain.value = 0.07; o.stop(ctx.currentTime + 0.4)`,
/// calls.js:907-910). CallService loops this every 2 s while a call rings (the
/// PWA's `setInterval(playBeep, 2000)`, calls.js:913). Kept here next to the
/// notification sounds so it reuses the same [renderSoundWav] synthesis +
/// audioplayers playback rather than a second audio engine. Not part of
/// [kNotificationSounds] — it isn't a user-selectable `settings.sound` value.
const SoundDescriptor kIncomingCallRingtone = SoundDescriptor(
  wave: SoundWave.sine,
  gain: 0.07,
  notes: [SoundNote(f: 480, d: 0.4)],
);

/// Resolve a `settings.sound` value to its descriptor, honoring legacy aliases.
/// Returns null for `'none'` (Silent) or any unknown value — matching
/// notifications.js where an unknown key short-circuits `playSound`.
SoundDescriptor? resolveSound(String type) {
  if (type == 'none') return null;
  final key = kLegacySoundAliases[type] ?? type;
  return kNotificationSounds[key];
}

/// True when the selection produces audible output. `'none'` => silent.
bool soundIsAudible(String type) => resolveSound(type) != null;

/// Renders a descriptor to a 16-bit mono PCM WAV byte buffer at [sampleRate].
///
/// Faithfully reproduces notifications.js `playSound`'s per-note gain envelopes:
/// - attack (`a`): ramp 0→gain over `a`, then exp-decay to ~0 by `d`.
/// - hold (`h`): hold gain until `h`, then exp-decay to ~0 by `d`.
/// - very short (`d < 0.06`): hold then linear release (anti-click).
/// - default: hold then exp-decay to ~0 by `d`.
/// Oscillators use the descriptor wave; `f2` glides exponentially f→f2 over `d`;
/// `chord` sums multiple sines/waves; `noise` is bandpass-ish filtered white
/// noise (approximated with a simple resonant band emphasis).
Uint8List renderSoundWav(SoundDescriptor sound, {int sampleRate = 44100}) {
  final total = sound.totalDuration;
  final totalSamples = max(1, (total * sampleRate).ceil());
  final samples = Float64List(totalSamples);

  var cursor = 0.0; // seconds
  final rng = Random(1); // deterministic noise for reproducibility
  for (final note in sound.notes) {
    final startSample = (cursor * sampleRate).floor();
    final noteSamples = max(1, (note.d * sampleRate).ceil());
    final gain = note.g ?? sound.gain;

    for (var i = 0; i < noteSamples; i++) {
      final t = i / sampleRate; // seconds into the note
      final env = _envelope(note, t, gain);
      if (env <= 0) continue;

      double sample;
      if (note.noise) {
        // Bandpass-filtered white noise approximated by white noise scaled by
        // a resonance factor — good enough for the rare noise notes (none in
        // the active 4 sounds; kept for table fidelity).
        sample = (rng.nextDouble() * 2 - 1);
      } else {
        final freqs = note.chord ?? [note.f ?? 0];
        double acc = 0;
        for (final f0 in freqs) {
          final freq = _glideFreq(f0, note.f2, note.d, t);
          acc += _osc(sound.wave, freq, t, cursor);
        }
        sample = acc;
      }

      final idx = startSample + i;
      if (idx >= 0 && idx < totalSamples) {
        samples[idx] += sample * env;
      }
    }
    cursor += note.d + note.gap;
  }

  return _encodeWav(samples, sampleRate);
}

/// Per-note gain envelope value at time [t] (seconds into the note).
double _envelope(SoundNote note, double t, double gain) {
  final d = note.d;
  if (note.a != null) {
    final a = note.a!;
    if (t < a) return gain * (t / a);
    // exponential decay from gain to ~0.001 by d
    return _expRamp(gain, 0.001, a, d, t);
  }
  if (note.h != null) {
    final h = note.h!;
    if (t <= h) return gain;
    return _expRamp(gain, 0.001, h, d, t);
  }
  if (d < 0.06) {
    final rel = d - 0.01;
    if (t <= rel) return gain;
    // linear release to ~0 by d
    final frac = ((d - t) / (d - rel)).clamp(0.0, 1.0);
    return gain * frac;
  }
  // default: hold at start then exp-decay to ~0.001 by d
  return _expRamp(gain, 0.001, 0, d, t);
}

double _expRamp(double from, double to, double t0, double t1, double t) {
  if (t <= t0) return from;
  if (t >= t1) return to;
  final frac = (t - t0) / (t1 - t0);
  // exponential interpolation (matches setTarget/exponentialRampToValueAtTime)
  return from * pow(to / from, frac).toDouble();
}

double _glideFreq(double f0, double? f2, double d, double t) {
  if (f2 == null || d <= 0) return f0;
  final frac = (t / d).clamp(0.0, 1.0);
  return f0 * pow(f2 / f0, frac).toDouble();
}

double _osc(SoundWave wave, double freq, double t, double phaseOffset) {
  final ph = 2 * pi * freq * t;
  switch (wave) {
    case SoundWave.sine:
      return sin(ph);
    case SoundWave.square:
      return sin(ph) >= 0 ? 1.0 : -1.0;
    case SoundWave.triangle:
      return (2 / pi) * asin(sin(ph));
    case SoundWave.sawtooth:
      final cycle = (freq * t) % 1.0;
      return 2 * cycle - 1;
  }
}

Uint8List _encodeWav(Float64List samples, int sampleRate) {
  // Soft-clip then convert to 16-bit PCM.
  final n = samples.length;
  final bytesPerSample = 2;
  final dataSize = n * bytesPerSample;
  final buffer = ByteData(44 + dataSize);

  void writeString(int offset, String s) {
    for (var i = 0; i < s.length; i++) {
      buffer.setUint8(offset + i, s.codeUnitAt(i));
    }
  }

  writeString(0, 'RIFF');
  buffer.setUint32(4, 36 + dataSize, Endian.little);
  writeString(8, 'WAVE');
  writeString(12, 'fmt ');
  buffer.setUint32(16, 16, Endian.little); // PCM chunk size
  buffer.setUint16(20, 1, Endian.little); // PCM format
  buffer.setUint16(22, 1, Endian.little); // mono
  buffer.setUint32(24, sampleRate, Endian.little);
  buffer.setUint32(28, sampleRate * bytesPerSample, Endian.little); // byte rate
  buffer.setUint16(32, bytesPerSample, Endian.little); // block align
  buffer.setUint16(34, 16, Endian.little); // bits per sample
  writeString(36, 'data');
  buffer.setUint32(40, dataSize, Endian.little);

  for (var i = 0; i < n; i++) {
    var v = samples[i];
    if (v > 1) v = 1;
    if (v < -1) v = -1;
    buffer.setInt16(44 + i * 2, (v * 32767).round(), Endian.little);
  }
  return buffer.buffer.asUint8List();
}
