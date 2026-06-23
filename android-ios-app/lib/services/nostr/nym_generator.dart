import 'dart:math';

import '../../core/utils/nym_utils.dart';

/// Random nym generation, ported verbatim from the PWA `generateRandomNym`
/// (js/modules/users.js:208). Style 'fancy' = `adjective_noun#suffix`,
/// 'simple' = `nymNNNN#suffix`.
class NymGenerator {
  NymGenerator([Random? random]) : _rand = random ?? Random.secure();
  final Random _rand;

  static const List<String> adjectives = [
    'quantum', 'neon', 'cyber', 'shadow', 'plasma',
    'echo', 'nexus', 'void', 'flux', 'ghost',
    'phantom', 'stealth', 'cryptic', 'dark', 'neural',
    'binary', 'matrix', 'digital', 'virtual', 'zero',
    'null', 'nym', 'masked', 'hidden', 'cipher',
    'enigma', 'spectral', 'rogue', 'omega', 'alpha',
    'delta', 'sigma', 'vortex', 'turbo', 'razor',
    'blade', 'frost', 'storm', 'glitch', 'pixel',
    'hyper', 'proto', 'nano', 'micro', 'ultra',
    'silent', 'feral', 'lucid', 'primal', 'astral',
    'cobalt', 'onyx', 'crimson', 'obsidian', 'iron',
    'solar', 'lunar', 'stellar', 'cosmic', 'atomic',
    'toxic', 'rogue', 'rapid', 'swift', 'fierce',
  ];

  static const List<String> nouns = [
    'ghost', 'nomad', 'drift', 'pulse', 'wave',
    'spark', 'node', 'byte', 'mesh', 'link',
    'runner', 'hacker', 'coder', 'agent', 'proxy',
    'daemon', 'virus', 'worm', 'bot', 'droid',
    'reaper', 'shadow', 'wraith', 'specter', 'shade',
    'entity', 'unit', 'core', 'nexus', 'cypher',
    'breach', 'exploit', 'overflow', 'inject', 'root',
    'kernel', 'shell', 'terminal', 'console', 'script',
    'raven', 'wolf', 'viper', 'hawk', 'lynx',
    'phantom', 'signal', 'cipher', 'vector', 'forge',
    'circuit', 'photon', 'glider', 'shard', 'vault',
    'beacon', 'torrent', 'crypt', 'grid', 'orbit',
  ];

  /// Generates `adjective_noun#suffix` (fancy) or `nymNNNN#suffix` (simple).
  String generate(String pubkey, {String style = 'fancy'}) {
    final suffix = getPubkeySuffix(pubkey);
    if (style == 'simple') {
      final n = 1000 + _rand.nextInt(9000);
      return 'nym$n#$suffix';
    }
    final adj = adjectives[_rand.nextInt(adjectives.length)];
    final noun = nouns[_rand.nextInt(nouns.length)];
    return '${adj}_$noun#$suffix';
  }
}
