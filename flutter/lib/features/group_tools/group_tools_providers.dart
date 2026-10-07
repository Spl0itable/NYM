import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

import '../../core/crypto/schnorr.dart' as schnorr;
import '../../models/nostr_event.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../state/settings_provider.dart';
import '../../widgets/common/app_dialog.dart';
import '../calls/call_providers.dart';
import '../chat_tools/chat_tools_providers.dart' show KeyValueChatToolsPrefs;
import '../i18n/i18n.dart';
import '../mesh/mesh_controller.dart';
import '../toasts/toast_center.dart';
import 'group_tools.dart';
import 'group_tools_service.dart';

BuildContext? Function() groupToolsContext = () => null;

final groupToolsRevisionProvider = StateProvider<int>((ref) => 0);

Future<GtPosition?> currentGtPosition({bool prompt = true}) async {
  try {
    if (!await Geolocator.isLocationServiceEnabled()) return null;
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied && prompt) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) {
      return null;
    }
    final pos = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        timeLimit: Duration(seconds: 15),
      ),
    );
    return GtPosition(pos.latitude, pos.longitude, pos.accuracy);
  } catch (_) {
    return null;
  }
}

bool verifyGtEvent(Map<String, dynamic> ev) {
  try {
    final tags = [
      for (final t in (ev['tags'] as List))
        [for (final x in (t as List)) x.toString()],
    ];
    return schnorr.verifyEvent(
      NostrEvent(
        pubkey: ev['pubkey'] as String,
        createdAt: ev['created_at'] as int,
        kind: ev['kind'] as int,
        tags: tags,
        content: ev['content'] as String,
        sig: ev['sig'] as String,
      ),
    );
  } catch (_) {
    return false;
  }
}

final groupToolsProvider = Provider<GroupToolsService>((ref) {
  final kv = ref.watch(keyValueStoreProvider);
  NostrController ctl() => ref.read(nostrControllerProvider);
  final svc = GroupToolsService(
    KeyValueChatToolsPrefs(kv),
    GroupToolsHooks(
      selfPubkey: () => ref.read(appStateProvider).selfPubkey,
      online: () => ref.read(appStateProvider).connectedRelays > 0,
      group: (id) => ref.read(appStateProvider.notifier).groupById(id),
      saveGroup: (g) {
        ref.read(appStateProvider.notifier).upsertGroup(g);
        ref.read(appStateProvider.notifier).notifyGroupsChanged();
      },
      messages: (key) => ref.read(appStateProvider).messages[key] ?? const [],
      sendGroupControl: (g, type, extra, recipients, {String content = ''}) =>
          ctl().gtSendGroupControl(
            g,
            type,
            extra,
            recipients,
            content: content,
          ),
      sendDirect: (to, tags, content) => ctl().gtSendDirect(to, tags, content),
      broadcastMetadata: (g) => ctl().gtBroadcastMetadata(g),
      addMember: (gid, pk) => ctl().addGroupMembers(gid, [pk]),
      sendGroupContent: (gid, content) =>
          ctl().gtSendGroupContent(gid, content),
      sendPmContent: (pk, content) => ctl().gtSendPmContent(pk, content),
      meshPeerFor: (pk) =>
          ref.read(meshControllerProvider.notifier).bridge?.peerIdForPubkey(pk),
      sendMeshPm: (pk, content) => ctl().gtSendMeshPm(pk, content),
      notice: (text) => showToast(text),
      notify: (title, body, route, type) =>
          ctl().gtNotify(title: title, body: body, route: route, type: type),
      nymOf: (pk) => ctl().gtNym(pk),
      sign: (template) => ctl().gtSign(template),
      verify: verifyGtEvent,
      sendCallSignal: (to, payload) async {
        await ctl().sendCallSignal(to: to, payload: payload);
      },
      confirm: (message, {title, okLabel, cancelLabel}) async {
        final c = groupToolsContext();
        if (c == null || !c.mounted) return false;
        return showAppConfirm(
          c,
          message,
          title: title,
          okLabel: okLabel,
          cancelLabel: cancelLabel,
        );
      },
      admitToCall: (link, joiner) =>
          ref.read(callServiceProvider).admitViaLink(link, joiner),
      position: () => currentGtPosition(prompt: false),
      onSyncChanged: () {
        try {
          ctl().syncSettings();
        } catch (_) {}
      },
      onChanged: () {
        ref.read(groupToolsRevisionProvider.notifier).state++;
        ref.read(appStateProvider.notifier).touch();
      },
      translate: (text, [vars]) => tr(text, vars),
    ),
  );
  ref.onDispose(svc.dispose);
  return svc;
});

String gtSurfaceForView(ChatView v) {
  switch (v.kind) {
    case ViewKind.group:
      return 'group';
    case ViewKind.pm:
      return 'dm';
    default:
      return 'channel';
  }
}

String gtTr(String text, [Map<String, String>? vars]) => tr(text, vars);

String gtSlowmodeLabel(int sec) => tr(GroupTools.slowmodeLabel(sec));
