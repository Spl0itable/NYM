import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils/nym_utils.dart';
import '../../services/nostr/nostr_service.dart';
import '../../services/notification_service.dart';
import '../../services/storage/key_value_store.dart';
import '../../services/storage/revocable_prefs.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../state/settings_provider.dart';
import '../i18n/i18n.dart';
import '../toasts/toast_center.dart';
import 'account_logic.dart';
import 'account_runtime.dart';
import 'inactive_probe.dart';

abstract class AccountsController {
  ValueListenable<AccountIndex> get changes;
  bool get busy;
  Future<bool> switchTo(String id);
  Future<String?> add();
  Future<bool> cancelAdd();
  Future<bool> remove(String id);
  Future<bool> logout();
  Future<bool> logoutAll();
  Future<String?> setNotify(String id, bool on);
  Future<void> register({
    required String pubkey,
    required String method,
    required String nym,
    String? avatar,
  });
  bool biometricHeldByOther();
  Future<String?> storedNsec(String id);
  Future<void> runInactiveProbes();
  void forgetAll();
  String? savedElsewhere(String pubkey);
}

final accountsProvider = Provider<AccountsController?>((ref) => null);

class AccountAlreadySaved implements Exception {
  const AccountAlreadySaved(this.nym);

  final String nym;
}

const String kAccountPayloadPrefix = 'nymchat-account:';

class AccountSession extends ChangeNotifier implements AccountsController {
  AccountSession({
    required this.runtime,
    this.overrides,
    this.probe,
    this._detach,
  }) {
    _container = _build();
  }

  final AccountRuntime runtime;
  final List<Override> Function()? overrides;
  final InactiveProbe? probe;
  Future<void> Function()? _detach;
  ProviderContainer? _container;
  int _generation = 0;
  bool _busy = false;
  bool _probing = false;
  bool _disposed = false;

  ProviderContainer? get container => _container;

  int get generation => _generation;

  set detach(Future<void> Function()? fn) => _detach = fn;

  @override
  ValueListenable<AccountIndex> get changes => runtime.changes;

  @override
  bool get busy => _busy;

  @override
  void dispose() {
    _disposed = true;
    _container?.dispose();
    _container = null;
    super.dispose();
  }

  RevocablePrefs? _prefs;

  ProviderContainer _build() {
    final prefs = RevocablePrefs(runtime.prefs);
    _prefs = prefs;
    return ProviderContainer(
      overrides: [
        keyValueStoreProvider.overrideWithValue(KeyValueStore(prefs)),
        sharedPrefsProvider.overrideWith((ref) async => prefs),
        accountsProvider.overrideWithValue(this),
        ...?overrides?.call(),
      ],
    );
  }

  int _unreadOf(ProviderContainer c) {
    try {
      if (!c.exists(nostrControllerProvider)) return 0;
      return c.read(nostrControllerProvider).unreadTotal();
    } catch (_) {
      return 0;
    }
  }

  Future<bool> _execute(AccountPlan plan) async {
    if (!plan.ok) return false;
    if (!plan.needsBoot) {
      await runtime.commit(plan);
      return true;
    }
    _busy = true;
    try {
      final old = _container;
      final leaving = runtime.active;
      final keep = !plan.effects.contains('clear');
      var seen = const <String>[];
      if (old != null) {
        if (old.exists(nostrControllerProvider)) {
          try {
            await old
                .read(nostrControllerProvider)
                .suspendForAccountSwitch(persist: keep)
                .timeout(const Duration(seconds: 15));
          } catch (_) {}
        }
        seen = NostrService.recentProcessedWraps(InactiveProbe.seenCap);
        _prefs?.revoke();
        _container = null;
        if (!_disposed) notifyListeners();
        final detach = _detach;
        if (detach != null) await detach();
        try {
          old.dispose();
        } catch (_) {}
      }
      NostrService.forgetProcessedWraps();
      await NotificationService.cancelEverything();
      await runtime.commit(plan);
      final p = probe;
      if (keep &&
          leaving != null &&
          p != null &&
          runtime.index.byId(leaving.id) != null) {
        try {
          await p.baseline(leaving.id, seen);
        } catch (_) {}
      }
      if (_disposed) return true;
      _container = _build();
      _generation++;
      notifyListeners();
    } finally {
      _busy = false;
    }
    return true;
  }

  @override
  Future<bool> switchTo(String id) async {
    if (_busy) return false;
    final c = _container;
    final plan = runtime.plan(
        SwitchAccountOp(id, unread: c == null ? 0 : _unreadOf(c)));
    return _execute(plan);
  }

  @override
  Future<String?> add() async {
    if (_busy) return 'busy';
    final plan = runtime.plan(AddAccountOp(runtime.newId(), runtime.now()));
    if (!plan.ok) return plan.error;
    await _execute(plan);
    return null;
  }

  @override
  Future<bool> cancelAdd() async {
    if (_busy) return false;
    return _execute(runtime.plan(const CancelAddOp()));
  }

  @override
  Future<bool> remove(String id) async {
    if (_busy) return false;
    return _execute(runtime.plan(RemoveAccountOp(id)));
  }

  @override
  Future<bool> logout() async {
    if (_busy) return false;
    return _execute(runtime.plan(const LogoutOp()));
  }

  @override
  Future<bool> logoutAll() async {
    if (_busy) return false;
    return _execute(runtime.plan(const LogoutAllOp()));
  }

  @override
  Future<String?> setNotify(String id, bool on) async {
    if (_busy) return 'busy';
    final plan = runtime.plan(NotifyOp(id, on: on));
    if (!plan.ok) return plan.error;
    await runtime.commit(plan);
    return null;
  }

  @override
  Future<void> register({
    required String pubkey,
    required String method,
    required String nym,
    String? avatar,
  }) async {
    if (_busy || pubkey.isEmpty || method.isEmpty) return;
    final cur = runtime.active;
    if (cur == null ||
        cur.pubkey != pubkey ||
        cur.method != method ||
        cur.nym != nym) {
      final plan = runtime.plan(RegisterAccountOp(
        pubkey: pubkey,
        method: method,
        nym: nym,
        id: runtime.newId(),
        now: runtime.now(),
      ));
      final existing = runtime.index.byId(plan.existing);
      if (plan.result == 'duplicate' && existing != null) {
        final name = getNymFromPubkey(
            existing.nym.isEmpty ? 'nym' : existing.nym, existing.pubkey);
        showToast(plan.ok
            ? tr('{nym} is already saved on this device, so the app switches '
                'to it.', {'nym': name})
            : tr('This key is also saved as {nym}. Switch to it from the '
                'account switcher.', {'nym': name}));
      }
      await _execute(plan);
    }
    if (avatar != null && !_busy && runtime.active?.pubkey == pubkey) {
      await runtime.touchActive(avatar: avatar);
    }
  }

  @override
  bool biometricHeldByOther() => runtime.biometricHeldByOther();

  @override
  Future<String?> storedNsec(String id) async {
    for (final key in const ['nym_nostr_login_nsec', 'nym_session_nsec']) {
      final v = await runtime.storedSecret(id, key);
      if (v != null && v.startsWith('nsec1')) return v;
    }
    return null;
  }

  @override
  void forgetAll() => runtime.forget();

  @override
  String? savedElsewhere(String pubkey) {
    final cur = runtime.active;
    if (cur == null || cur.isPlaceholder) return null;
    for (final a in runtime.index.accounts) {
      if (a.id != cur.id && a.pubkey == pubkey) {
        return getNymFromPubkey(a.nym.isEmpty ? 'nym' : a.nym, a.pubkey);
      }
    }
    return null;
  }

  @override
  Future<void> runInactiveProbes() async {
    final p = probe;
    if (p == null || _probing || _busy) return;
    _probing = true;
    try {
      for (final a in runtime.index.accounts) {
        if (a.id == runtime.index.active || !a.notifyInactive) continue;
        final fresh = await p.probe(a);
        if (fresh <= 0) continue;
        final label = getNymFromPubkey(a.nym.isEmpty ? 'nym' : a.nym, a.pubkey);
        try {
          await NotificationService().showNotification(
            title: 'Nymchat',
            body: tr('New message for {nym}', {'nym': label}),
            payload: '$kAccountPayloadPrefix${a.id}',
            conversationKey: 'account-${a.id}',
          );
        } catch (_) {}
      }
    } finally {
      _probing = false;
    }
  }
}

class AccountHost extends StatefulWidget {
  const AccountHost({
    super.key,
    required this.session,
    required this.builder,
    this.probeEvery = const Duration(minutes: 10),
  });

  final AccountSession session;
  final Widget Function() builder;
  final Duration probeEvery;

  @override
  State<AccountHost> createState() => _AccountHostState();
}

class _AccountHostState extends State<AccountHost> {
  Timer? _probeTimer;

  @override
  void initState() {
    super.initState();
    widget.session.detach = () => WidgetsBinding.instance.endOfFrame;
    if (widget.session.probe != null) {
      _probeTimer = Timer.periodic(widget.probeEvery, (_) {
        unawaited(widget.session.runInactiveProbes());
      });
    }
  }

  @override
  void dispose() {
    _probeTimer?.cancel();
    widget.session.detach = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.session,
      builder: (context, _) {
        final c = widget.session.container;
        if (c == null) return const _SwitchingScreen();
        return UncontrolledProviderScope(
          key: ValueKey(widget.session.generation),
          container: c,
          child: _AccountReporter(child: widget.builder()),
        );
      },
    );
  }
}

class _SwitchingScreen extends StatelessWidget {
  const _SwitchingScreen();

  @override
  Widget build(BuildContext context) {
    return const Directionality(
      textDirection: TextDirection.ltr,
      child: ColoredBox(
        color: Color(0xFF000000),
        child: Center(
          child: SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      ),
    );
  }
}

class _AccountReporter extends ConsumerStatefulWidget {
  const _AccountReporter({required this.child});

  final Widget child;

  @override
  ConsumerState<_AccountReporter> createState() => _AccountReporterState();
}

class _AccountReporterState extends ConsumerState<_AccountReporter> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 2), (_) => _report());
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  void _report() {
    if (!mounted) return;
    final api = ref.read(accountsProvider);
    if (api == null || api.busy) return;
    try {
      final kv = ref.read(keyValueStoreProvider);
      final method = AccountLogic.methodFromStorage(kv.getString);
      if (method.isEmpty) return;
      final st = ref.read(appStateProvider);
      final login = kv.getString('nym_nostr_login_pubkey') ?? '';
      final durable = method == 'nsec' || method == 'extension' || method == 'nip46';
      final pubkey = durable && login.length == 64 ? login : st.selfPubkey;
      if (pubkey.length != 64) return;
      final stored = AccountLogic.nymFromStorage(kv.getString, method);
      final nym = stored.isNotEmpty ? stored : splitNymSuffix(st.selfNym).base;
      final avatar = st.users[pubkey]?.profile?.picture;
      unawaited(api.register(
        pubkey: pubkey,
        method: method,
        nym: nym,
        avatar: avatar,
      ));
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
