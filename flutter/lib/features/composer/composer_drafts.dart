import '../../state/app_state.dart';

typedef SendAsDraft = ({
  String composed,
  ({String author, String text, String fullText})? quote,
  String quoteId,
});

class ComposerDrafts {
  ComposerDrafts._();

  static final Map<String, String> _drafts = {};
  static final Map<String, String> _kept = {};

  static String keyFor(ChatView view, {String owner = ''}) {
    final base = switch (view.kind) {
      ViewKind.group => 'g:${view.id}',
      ViewKind.pm => 'p:${view.id}',
      ViewKind.channel => 'c:${view.id}',
    };
    return owner.isEmpty ? base : '$owner|$base';
  }

  static void save(String key, String value) {
    if (value.trim().isNotEmpty) {
      _drafts[key] = value;
    } else {
      _drafts.remove(key);
    }
  }

  static String restore(String key) {
    final draft = _drafts[key] ?? '';
    final kept = _kept.remove(key);
    if (kept == null || kept.isEmpty || draft.contains(kept)) return draft;
    final next = draft.trim().isEmpty ? kept : '$draft\n$kept';
    _drafts[key] = next;
    return next;
  }

  static void keep(String key, String text) {
    if (text.trim().isEmpty) return;
    final cur = _kept[key] ?? '';
    if (cur.contains(text)) return;
    _kept[key] = cur.trim().isEmpty ? text : '$cur\n$text';
  }

  static final Map<String, SendAsDraft> failedSendAs = {};
}
