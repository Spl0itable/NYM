import 'dart:async';

import '../core/constants/storage_keys.dart';
import '../services/storage/key_value_store.dart';
import 'app_state.dart';

ChatView? parseLastView(String? raw) {
  if (raw == null) return null;
  if (raw.startsWith('#') && raw.length > 1) {
    return ChatView.channel(raw.substring(1));
  }
  if (raw.startsWith('pm-') && raw.length > 3) {
    return ChatView.pm(raw.substring(3));
  }
  if (raw.startsWith('group-') && raw.length > 6) {
    return ChatView.group(raw.substring(6));
  }
  return null;
}

void rememberLastView(KeyValueStore kv, ChatView view) {
  if (kv.getString(StorageKeys.lastView) == view.storageKey) return;
  unawaited(kv.setString(StorageKeys.lastView, view.storageKey));
}

bool lastViewStillExists(
  ChatView view,
  AppState state, {
  required bool Function(String groupId) isLeftGroup,
}) {
  switch (view.kind) {
    case ViewKind.channel:
      return !state.blockedChannels.contains(view.id.toLowerCase());
    case ViewKind.pm:
      if (view.id == kNymbotPubkey) return true;
      if (state.blockedUsers.contains(view.id)) return false;
      return state.pmConversations.any((c) => c.pubkey == view.id);
    case ViewKind.group:
      if (isLeftGroup(view.id)) return false;
      return state.groups.any((g) => g.id == view.id);
  }
}

class BootViewRestore {
  BootViewRestore(this._appState, this._kv)
      : _switchesAtStart = _appState.viewSwitchCount;

  final AppStateNotifier _appState;
  final KeyValueStore _kv;
  final int _switchesAtStart;
  int? _switchesAtLive;
  ChatView? _requested;

  void beforeGoLive() {
    if (_appState.viewSwitchCount != _switchesAtStart) {
      _requested = _appState.currentView;
    }
  }

  void afterGoLive() {
    _switchesAtLive = _appState.viewSwitchCount;
  }

  ChatView? apply() {
    final atLive = _switchesAtLive;
    if (atLive == null || _appState.viewSwitchCount != atLive) return null;
    final requested = _requested;
    if (requested != null) {
      _open(requested, ensurePm: true);
      return requested;
    }
    final remembered = parseLastView(_kv.getString(StorageKeys.lastView));
    if (remembered == null) return null;
    if (!lastViewStillExists(remembered, _appState.currentState,
        isLeftGroup: _appState.isLeftGroup)) {
      unawaited(_kv.remove(StorageKeys.lastView));
      return null;
    }
    if (remembered == _appState.currentView) return null;
    _open(remembered, ensurePm: false);
    return remembered;
  }

  void _open(ChatView view, {required bool ensurePm}) {
    switch (view.kind) {
      case ViewKind.channel:
        _appState.switchChannel(view.id);
      case ViewKind.pm:
        if (ensurePm && view.id != kNymbotPubkey) {
          _appState.ensurePMConversation(view.id);
        }
        _appState.switchView(view);
      case ViewKind.group:
        _appState.switchView(view);
    }
  }
}
