import 'dart:collection';
import 'dart:convert';

import '../../core/constants/event_kinds.dart';
import '../../models/group.dart';
import '../../models/message.dart';
import '../../models/nostr_event.dart';
import '../../models/poll.dart';
import '../../state/app_state.dart';
import '../chat_tools/chat_tools_service.dart' show ChatToolsPrefs;
import 'dm_polls.dart';

class DmPollsKeys {
  DmPollsKeys._();
  static const String votes = 'nym_dm_poll_votes_';
}

class DmPollsHooks {
  const DmPollsHooks({
    required this.selfPubkey,
    required this.group,
    required this.findMessage,
    this.isBot,
    this.sendPm,
    this.sendGroup,
    this.sendControl,
    this.newId,
    this.notice,
    this.onChanged,
    this.now,
    this.translate,
  });

  final String Function() selfPubkey;
  final Group? Function(String groupId) group;
  final Message? Function(String pollId) findMessage;
  final bool Function(String pubkey)? isBot;
  final Future<bool> Function(String pubkey, String content)? sendPm;
  final Future<bool> Function(String groupId, String content)? sendGroup;
  final Future<bool> Function(
    UnsignedEvent rumor,
    List<String> recipients,
    String? groupId,
  )? sendControl;
  final String Function()? newId;
  final void Function(String text)? notice;
  final void Function()? onChanged;
  final int Function()? now;
  final String Function(String text, [Map<String, String>? vars])? translate;

  DmPollsHooks copyWith({
    Future<bool> Function(String pubkey, String content)? sendPm,
    Future<bool> Function(String groupId, String content)? sendGroup,
    Future<bool> Function(
      UnsignedEvent rumor,
      List<String> recipients,
      String? groupId,
    )? sendControl,
    void Function(String text)? notice,
    int Function()? now,
  }) =>
      DmPollsHooks(
        selfPubkey: selfPubkey,
        group: group,
        findMessage: findMessage,
        isBot: isBot,
        sendPm: sendPm ?? this.sendPm,
        sendGroup: sendGroup ?? this.sendGroup,
        sendControl: sendControl ?? this.sendControl,
        newId: newId,
        notice: notice ?? this.notice,
        onChanged: onChanged,
        now: now ?? this.now,
        translate: translate,
      );
}

class DmPollView {
  const DmPollView({
    required this.pollId,
    required this.poll,
    required this.tally,
    required this.mine,
    required this.canVote,
    required this.canClose,
  });

  final String pollId;
  final DmPoll poll;
  final DmPollTally tally;
  final int? mine;
  final bool canVote;
  final bool canClose;
}

class DmPollsService {
  DmPollsService(this._prefs, this.hooks);

  final ChatToolsPrefs _prefs;
  final DmPollsHooks hooks;

  Map<String, DmPollEntry>? _store;
  String? _storePk;

  String get _self => hooks.selfPubkey();
  int get _nowSec =>
      (hooks.now?.call() ?? DateTime.now().millisecondsSinceEpoch) ~/ 1000;

  String _t(String text, [Map<String, String>? vars]) {
    final tr = hooks.translate;
    if (tr != null) return tr(text, vars);
    var out = text;
    vars?.forEach((k, v) => out = out.replaceAll('{$k}', v));
    return out;
  }

  void _notice(String text) => hooks.notice?.call(_t(text));

  Map<String, DmPollEntry> store() {
    final pk = _self;
    final cached = _store;
    if (cached != null && _storePk == pk) return cached;
    final out = <String, DmPollEntry>{};
    try {
      final raw = _prefs.read('${DmPollsKeys.votes}$pk');
      final decoded = raw == null || raw.isEmpty ? null : jsonDecode(raw);
      if (decoded is Map) {
        decoded.forEach((k, v) {
          if (k is String) out[k] = DmPollEntry.fromJson(v);
        });
      }
    } catch (_) {}
    _storePk = pk;
    return _store = out;
  }

  void _save() {
    final pruned = DmPolls.prune(store());
    _store = pruned;
    _prefs.write(
      '${DmPollsKeys.votes}${_storePk ?? _self}',
      jsonEncode({for (final e in pruned.entries) e.key: e.value.toJson()}),
    );
  }

  void _changed() => hooks.onChanged?.call();

  String refusal(ChatView view) {
    if (view.kind == ViewKind.pm && (hooks.isBot?.call(view.id) ?? false)) {
      return _t(DmPollStrings.botRefused);
    }
    return '';
  }

  Future<bool> publish(ChatView view, String question, List<String> options) async {
    if (view.kind == ViewKind.channel) return false;
    final content = DmPolls.buildPollContent(question, options);
    if (content == null) return false;
    final refused = refusal(view);
    if (refused.isNotEmpty) {
      hooks.notice?.call(refused);
      return false;
    }
    final ok = view.kind == ViewKind.group
        ? await hooks.sendGroup?.call(view.id, content) ?? false
        : await hooks.sendPm?.call(view.id, content) ?? false;
    if (!ok) _notice(DmPollStrings.sendFailed);
    return ok;
  }

  static bool isPollMessage(Message m) =>
      (m.isPM || m.isGroup) &&
      (m.nymMessageId?.isNotEmpty ?? false) &&
      DmPolls.parsePoll(m.content) != null;

  static bool blocksEdit(ChatView view, String content) =>
      view.inPMMode && DmPolls.parsePoll(content) != null;

  ({Message msg, DmPoll poll})? _locate(String pollId) {
    final m = hooks.findMessage(pollId);
    if (m == null || m.nymMessageId != pollId) return null;
    final poll = DmPolls.parsePoll(m.content);
    return poll == null ? null : (msg: m, poll: poll);
  }

  String? _peer(Message m) {
    final p = m.conversationPubkey;
    if (p != null && p.isNotEmpty) return p;
    return m.isOwn ? null : m.pubkey;
  }

  List<String> allowed(Message m) {
    if (m.isGroup) {
      final g = m.groupId == null ? null : hooks.group(m.groupId!);
      if (g == null) return const [];
      final out = List<String>.of(g.members);
      final owner = g.createdBy;
      if (owner != null && owner.isNotEmpty && !out.contains(owner)) {
        out.add(owner);
      }
      return out;
    }
    final peer = _peer(m);
    return [
      if (_self.isNotEmpty) _self,
      ?peer,
    ];
  }

  DmPollTally tallyFor(Message m, DmPoll poll) => DmPolls.tally(
        store()[m.nymMessageId],
        options: poll.options.length,
        author: m.pubkey,
        allowed: allowed(m),
      );

  DmPollView? viewFor(Message m) {
    if (!isPollMessage(m)) return null;
    final poll = DmPolls.parsePoll(m.content)!;
    final t = tallyFor(m, poll);
    final self = _self;
    return DmPollView(
      pollId: m.nymMessageId!,
      poll: poll,
      tally: t,
      mine: t.choices[self],
      canVote: !t.closed && allowed(m).contains(self),
      canClose: m.pubkey == self && !t.closed,
    );
  }

  Poll asPoll(Message m, DmPollView v) => Poll(
        id: v.pollId,
        question: v.poll.question,
        options: [
          for (var i = 0; i < v.poll.options.length; i++)
            PollOption(index: i, text: v.poll.options[i]),
        ],
        votes: LinkedHashMap.of({
          for (final pk in v.tally.order) pk: v.tally.choices[pk]!,
        }),
        pubkey: m.pubkey,
        createdAt: m.createdAt,
      );

  UnsignedEvent? controlRumor(
    Message m,
    List<List<String>> extra,
    String content,
    int ts,
  ) {
    final tags = <List<String>>[];
    if (m.isGroup) {
      final g = m.groupId == null ? null : hooks.group(m.groupId!);
      if (g == null) return null;
      for (final pk in g.members) {
        tags.add(['p', pk]);
      }
      tags.add(['g', g.id]);
      if (g.name.isNotEmpty) tags.add(['subject', g.name]);
    } else {
      final peer = _peer(m);
      if (peer == null) return null;
      tags.add(['p', peer]);
    }
    tags.addAll(extra);
    final id = hooks.newId?.call();
    if (id == null || id.isEmpty) return null;
    tags.add(['x', id]);
    return UnsignedEvent(
      pubkey: _self,
      createdAt: ts,
      kind: EventKind.dmRumor,
      tags: tags,
      content: content,
    );
  }

  Future<void> _send(Message m, UnsignedEvent rumor) async {
    final send = hooks.sendControl;
    if (send == null) return;
    if (m.isGroup) {
      final g = m.groupId == null ? null : hooks.group(m.groupId!);
      if (g == null) return;
      await send(rumor, List<String>.of(g.members), g.id);
      return;
    }
    final peer = _peer(m);
    if (peer == null) return;
    await send(rumor, [_self, peer], null);
  }

  Future<void> vote(String pollId, int optionIndex) async {
    final loc = _locate(pollId);
    if (loc == null) return;
    final m = loc.msg;
    final poll = loc.poll;
    if (optionIndex < 0 || optionIndex >= poll.options.length) return;
    final self = _self;
    if (!allowed(m).contains(self)) return;
    final t = tallyFor(m, poll);
    if (t.closed) {
      _notice(DmPollStrings.closedNotice);
      return;
    }
    if (t.choices[self] == optionIndex) return;
    final s = store();
    final ts = DmPolls.nextVoteTs(s[pollId], self, _nowSec);
    final rumor = controlRumor(
      m,
      DmPolls.voteTags(pollId, optionIndex),
      DmPolls.voteContent(poll.options[optionIndex]),
      ts,
    );
    if (rumor == null) return;
    s[pollId] = DmPolls.applyVote(s[pollId], self, optionIndex, ts).entry;
    _save();
    _changed();
    await _send(m, rumor);
  }

  Future<void> close(String pollId) async {
    final loc = _locate(pollId);
    final self = _self;
    if (loc == null || loc.msg.pubkey != self) return;
    final m = loc.msg;
    if (tallyFor(m, loc.poll).closed) return;
    final s = store();
    final ts = DmPolls.nextVoteTs(s[pollId], self, _nowSec);
    final rumor = controlRumor(
      m,
      DmPolls.closeTags(pollId),
      DmPolls.closeContent(loc.poll.question),
      ts,
    );
    if (rumor == null) return;
    s[pollId] = DmPolls.applyClose(s[pollId], self, ts).entry;
    _save();
    _changed();
    await _send(m, rumor);
  }

  bool handleControl(
    Map<String, dynamic> rumor,
    String sender,
    String? groupId,
    bool verified,
  ) {
    final c = DmPolls.parseControl(rumor, _nowSec);
    if (c == null) return false;
    if (!c.valid || !verified || sender.isEmpty) return true;
    if (groupId != null) {
      final g = hooks.group(groupId);
      if (g == null || !(g.createdBy == sender || g.members.contains(sender))) {
        return true;
      }
    }
    final s = store();
    final r = c.type == 'vote'
        ? DmPolls.applyVote(s[c.pollId], sender, c.option, c.ts)
        : DmPolls.applyClose(s[c.pollId], sender, c.ts);
    if (!r.changed) return true;
    s[c.pollId] = r.entry;
    _save();
    _changed();
    return true;
  }
}
