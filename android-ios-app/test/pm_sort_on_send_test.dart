import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/models/pm_conversation.dart';
import 'package:nym_bar/state/app_state.dart';

void main() {
  test('sending a PM raises its conversation above a more-recent one', () {
    final n = AppStateNotifier()..goLive('self_pk', 'me#0001');
    n.state.pmConversations.addAll([
      PMConversation(pubkey: 'peerA', nym: 'alice', lastMessageTime: 1000),
      PMConversation(pubkey: 'peerB', nym: 'bob', lastMessageTime: 5000),
    ]);
    // Open the OLDER conversation (peerA) and send — it must now sort ahead of
    // peerB, which was previously the most recent.
    n.switchView(const ChatView.pm('peerA'));
    n.sendLocal('hi there');

    final a = n.state.pmConversations.firstWhere((c) => c.pubkey == 'peerA');
    final b = n.state.pmConversations.firstWhere((c) => c.pubkey == 'peerB');
    expect(a.lastMessageTime, greaterThan(b.lastMessageTime));

    // And the sorted sidebar provider view puts peerA first.
    final sorted = [...n.state.pmConversations]
      ..sort((x, y) => y.lastMessageTime - x.lastMessageTime);
    expect(sorted.first.pubkey, 'peerA');
  });
}
