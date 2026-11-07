import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../core/utils/nym_utils.dart';
import '../../features/chat_lock/chat_lock_providers.dart';
import '../../features/chat_nav/chat_nav.dart' show pinKey, pinKeyForChat;
import '../../features/i18n/i18n.dart';
import '../../features/sidebar/sidebar_layout.dart';
import '../../features/sidebar_folders/folders.dart';
import '../../features/sidebar_folders/folders_providers.dart';
import '../../features/toasts/toast_center.dart';
import '../../state/app_state.dart';
import '../../state/settings_provider.dart';
import '../common/app_dialog.dart';
import '../common/nym_field.dart';
import '../nym_icons.dart';
import 'pm_context_menu.dart';
import 'sidebar_rows.dart';

class FolderIcons {
  const FolderIcons._();

  static const String folder =
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/></svg>';
  static const String move =
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/><polyline points="11 10 14 13 11 16"/><line x1="7" y1="13" x2="14" y2="13"/></svg>';
  static const String remove =
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/><line x1="9" y1="13" x2="15" y2="13"/></svg>';
  static const String rename =
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 20h9"/><path d="M16.5 3.5a2.12 2.12 0 0 1 3 3L7 19l-4 1 1-4Z"/></svg>';
  static const String trash =
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="3 6 5 6 21 6"/><path d="M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6"/><path d="M10 11v6"/><path d="M14 11v6"/></svg>';
}

bool folderError(String? code) {
  final msg = switch (code) {
    'folders' => tr(FoldersStrings.capFolders, {'n': FoldersLimits.folders}),
    'cap' => tr(FoldersStrings.capItems, {'n': FoldersLimits.perFolder}),
    'total' => tr(FoldersStrings.capTotal, {'n': FoldersLimits.total}),
    'long' => tr(FoldersStrings.nameLong, {'n': FoldersLimits.nameMax}),
    'name' => tr(FoldersStrings.nameEmpty),
    'size' => tr(FoldersStrings.capSize),
    _ => null,
  };
  if (msg != null) showToast(msg);
  return false;
}

Future<String?> _promptName(
    BuildContext context, String title, String ok, String initial) async {
  final v = await showAppPrompt(
    context,
    tr(FoldersStrings.folderName),
    title: tr(title),
    okLabel: tr(ok),
    cancelLabel: tr(FoldersStrings.cancel),
    defaultValue: initial,
    placeholder: tr(FoldersStrings.folderName),
    maxLength: FoldersLimits.nameMax,
    countCodePoints: true,
  );
  if (v == null) return null;
  final c = cleanFolderName(v);
  if (c.error != null) {
    folderError(c.error);
    return null;
  }
  return c.name;
}

Future<String> folderNew(BuildContext context, WidgetRef ref,
    {List<String> refs = const [], bool picker = false}) async {
  final service = ref.read(sidebarFoldersProvider);
  if (!service.ready) return '';
  final order = ref.read(sidebarSectionOrderProvider.notifier);
  final name = await _promptName(
      context, FoldersStrings.newFolder, FoldersStrings.create, '');
  if (name == null) return '';
  final id = service.newId();
  final r = folderCreate(service.state, id, name, service.nowMs, refs,
      order.current);
  if (r.error != null) {
    folderError(r.error);
    return '';
  }
  service.commit(r.state);
  if (refs.isNotEmpty) showToast(tr(FoldersStrings.added, {'folder': name}));
  if (picker && context.mounted) {
    unawaited(folderOpenPicker(context, ref, id));
  }
  return id;
}

Future<void> folderRenamePrompt(
    BuildContext context, WidgetRef ref, String fid) async {
  final service = ref.read(sidebarFoldersProvider);
  final f = service.state.folders[fid];
  if (f == null) return;
  final name = await _promptName(
      context, FoldersStrings.renameFolder, FoldersStrings.rename, f.name);
  if (name == null) return;
  final r = folderRename(service.state, fid, name, service.nowMs);
  if (r.error != null) {
    folderError(r.error);
    return;
  }
  service.commit(r.state);
}

Future<void> folderDeleteConfirm(
    BuildContext context, WidgetRef ref, String fid) async {
  final service = ref.read(sidebarFoldersProvider);
  if (!service.state.folders.containsKey(fid)) return;
  final ok = await showAppConfirm(
    context,
    tr(FoldersStrings.deleteConfirm),
    danger: true,
    okLabel: tr(FoldersStrings.del),
    cancelLabel: tr(FoldersStrings.cancel),
  );
  if (!ok || !context.mounted) return;
  folderDeleteNow(ref, fid);
}

void folderDeleteNow(WidgetRef ref, String fid) {
  final service = ref.read(sidebarFoldersProvider);
  final cur = service.state;
  final f = cur.folders[fid];
  if (f == null) return;
  final name = f.name;
  final refs = f.items.keys.toList();
  final index = effectiveLayout(cur, ref.read(sidebarSectionOrderProvider))
      .indexOf('f:$fid');
  final wasClosed = service.collapsed.contains(fid);
  service.commit(folderDelete(cur, fid, service.nowMs).state);
  showUndoToast(tr(FoldersStrings.deleted), () {
    final s = service;
    final id = s.newId();
    final r = folderRestore(s.state, id, name, refs, index, s.nowMs);
    if (r.error != null) {
      folderError(r.error);
      return;
    }
    s.commit(r.state);
    if (wasClosed) s.setCollapsed(id, true);
  });
}

bool folderMoveToken(WidgetRef ref, String token, int delta) {
  final service = ref.read(sidebarFoldersProvider);
  final order = ref.read(sidebarSectionOrderProvider);
  final r = layoutMove(service.state, token, delta, service.nowMs, order);
  if (r.error != null) return false;
  final builtins = folderBuiltinOrder(r.layout);
  final moved = builtins.join(',') != folderBuiltinOrder(order).join(',');
  service.commit(r.state, joinSettings: moved);
  if (moved) ref.read(sidebarSectionOrderProvider.notifier).setOrder(builtins);
  return true;
}

void folderAddRef(WidgetRef ref, String chatRef, String to, String from) {
  final service = ref.read(sidebarFoldersProvider);
  final r = folderAdd(service.state, to, [chatRef], service.nowMs);
  if (r.error != null) {
    folderError(r.error);
    return;
  }
  service.commit(r.state);
  final name = r.state.folders[to]?.name ?? '';
  showUndoToast(
      tr(from.isEmpty ? FoldersStrings.added : FoldersStrings.moved,
          {'folder': name}), () {
    final s = service;
    final cur = s.state;
    if (from.isNotEmpty && cur.folders.containsKey(from)) {
      s.commit(folderAdd(cur, from, [chatRef], s.nowMs).state);
    } else if (cur.folders.containsKey(to)) {
      s.commit(folderRemove(cur, to, [chatRef], s.nowMs).state);
    }
  });
}

void folderRemoveRef(WidgetRef ref, String chatRef, String fid) {
  final service = ref.read(sidebarFoldersProvider);
  final state = service.state;
  final f = state.folders[fid];
  if (f == null) return;
  final name = f.name;
  service.commit(folderRemove(state, fid, [chatRef], service.nowMs).state);
  showUndoToast(tr(FoldersStrings.removedFrom, {'folder': name}), () {
    final s = service;
    if (!s.state.folders.containsKey(fid)) return;
    final r = folderAdd(s.state, fid, [chatRef], s.nowMs);
    if (r.error != null) {
      folderError(r.error);
      return;
    }
    s.commit(r.state);
  });
}

Offset _menuAt(BuildContext context, Offset? at) {
  if (at != null) return at;
  final size = MediaQuery.sizeOf(context);
  return Offset(size.width / 2, size.height / 3);
}

void folderChooser(
    BuildContext context, WidgetRef ref, String chatRef, String from,
    [Offset? anchor]) {
  final service = ref.read(sidebarFoldersProvider);
  final items = <SidebarQuickMenuItem>[
    for (final f in folderList(service.state))
      if (f.id != from)
        SidebarQuickMenuItem(
          label: f.name,
          svg: FolderIcons.folder,
          onSelected: () => folderAddRef(ref, chatRef, f.id, from),
        ),
    SidebarQuickMenuItem(
      label: '${tr(FoldersStrings.newFolder)}…',
      svg: NymIcons.plus,
      onSelected: () {
        if (context.mounted) unawaited(folderNew(context, ref, refs: [chatRef]));
      },
    ),
  ];
  final at = _menuAt(context, anchor);
  Timer.run(() {
    if (context.mounted) unawaited(showSidebarQuickMenu(context, at, items));
  });
}

List<SidebarQuickMenuItem> folderSidebarItems(
    BuildContext context, WidgetRef ref, String storageKey, {Offset? at}) {
  final service = ref.read(sidebarFoldersProvider);
  if (!service.ready) return const [];
  final k = pinKeyForChat(storageKey);
  if (!folderValidRef(k)) return const [];
  final fid = folderOfState(service.state, k);
  if (fid.isEmpty) {
    return [
      SidebarQuickMenuItem(
        label: tr(FoldersStrings.addTo),
        svg: FolderIcons.folder,
        onSelected: () => folderChooser(context, ref, k, '', at),
      ),
    ];
  }
  return [
    SidebarQuickMenuItem(
      label: tr(FoldersStrings.moveTo),
      svg: FolderIcons.move,
      onSelected: () => folderChooser(context, ref, k, fid, at),
    ),
    SidebarQuickMenuItem(
      label: tr(FoldersStrings.removeFrom),
      svg: FolderIcons.remove,
      onSelected: () => folderRemoveRef(ref, k, fid),
    ),
  ];
}

Future<void> folderMenu(
    BuildContext context, WidgetRef ref, String fid, Offset at) {
  return showSidebarQuickMenu(context, at, [
    SidebarQuickMenuItem(
      label: tr(FoldersStrings.addChats),
      svg: NymIcons.plus,
      onSelected: () {
        if (context.mounted) unawaited(folderOpenPicker(context, ref, fid));
      },
    ),
    SidebarQuickMenuItem(
      label: tr(FoldersStrings.renameFolder),
      svg: FolderIcons.rename,
      onSelected: () {
        if (context.mounted) unawaited(folderRenamePrompt(context, ref, fid));
      },
    ),
    SidebarQuickMenuItem(
      label: tr(FoldersStrings.deleteFolder),
      svg: FolderIcons.trash,
      danger: true,
      onSelected: () {
        if (context.mounted) unawaited(folderDeleteConfirm(context, ref, fid));
      },
    ),
  ]);
}

typedef FolderPickRow = ({String ref, String label, String other});

List<FolderPickRow> folderPickerRows(WidgetRef ref, String fid) {
  final app = ref.read(appStateProvider);
  final state = ref.read(sidebarFoldersProvider).state;
  final chatLock = ref.read(chatLockProvider);
  final users = ref.read(usersProvider);
  final pmOnly = ref.read(settingsProvider).groupChatPMOnlyMode;
  final view = app.view;
  final out = <FolderPickRow>[];
  final seen = <String>{};
  String other(String r) {
    final f = folderOfState(state, r);
    return f.isEmpty || f == fid ? '' : state.folders[f]!.name;
  }

  if (!pmOnly) {
    for (final ch in app.channels) {
      final r = pinKey('channel', ch.key);
      if (!folderValidRef(r) || !seen.add(r)) continue;
      if (app.blockedChannels.contains(ch.key)) continue;
      if (app.hiddenChannels.contains(ch.key) &&
          !(view.kind == ViewKind.channel && view.id == ch.key)) {
        continue;
      }
      if (chatLock.isConversationLocked(ch.storageKey)) continue;
      out.add((ref: r, label: '#${ch.key}', other: other(r)));
    }
  }
  for (final pm in ref.read(pmListProvider)) {
    final r = pinKey('dm', pm.pubkey);
    if (!folderValidRef(r) || !seen.add(r)) continue;
    if (app.blockedUsers.contains(pm.pubkey)) continue;
    if (chatLock.isConversationLocked('pm-${pm.pubkey.toLowerCase()}')) continue;
    out.add((
      ref: r,
      label: '${pickDisplayNym(users[pm.pubkey]?.nym, pm.nym)}'
          '#${getPubkeySuffix(pm.pubkey)}',
      other: other(r),
    ));
  }
  for (final g in ref.read(groupsProvider)) {
    final r = pinKey('group', g.id);
    if (!folderValidRef(r) || !seen.add(r)) continue;
    if (chatLock.isConversationLocked('group-${g.id}')) continue;
    out.add((ref: r, label: app.groupLabel(g), other: other(r)));
  }
  final rank = <String, int>{};
  for (final r in ref.read(sidebarChannelRowsProvider).rows) {
    rank.putIfAbsent(pinKey('channel', r.item.key), () => rank.length);
  }
  for (final r in ref.read(sidebarPmRowsProvider).rows) {
    final e = r.item;
    rank.putIfAbsent(
        e.group != null ? pinKey('group', e.group!.id) : pinKey('dm', e.pm!.pubkey),
        () => rank.length);
  }
  final idx = {for (var i = 0; i < out.length; i++) out[i].ref: i};
  int kind(String r) => r.startsWith('c:') ? 0 : 1;
  out.sort((a, b) {
    final k = kind(a.ref) - kind(b.ref);
    if (k != 0) return k;
    final ra = rank[a.ref] ?? (1 << 30);
    final rb = rank[b.ref] ?? (1 << 30);
    if (ra != rb) return ra - rb;
    return idx[a.ref]! - idx[b.ref]!;
  });
  return out;
}

Future<void> folderOpenPicker(
    BuildContext context, WidgetRef ref, String fid) async {
  final service = ref.read(sidebarFoldersProvider);
  final folder = service.state.folders[fid];
  if (folder == null) return;
  final rows = folderPickerRows(ref, fid);
  final checked = {for (final r in rows) if (folder.items.containsKey(r.ref)) r.ref};
  final picker = ref.read(sidebarFolderPickerProvider.notifier);
  var selection = checked;
  while (context.mounted) {
    picker.open(fid, selection);
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => FolderPickerDialog(rows: rows),
    );
    final pick = picker.current;
    picker.close();
    if (ok != true || pick == null || pick.fid != fid) return;
    final cur = service;
    if (!cur.state.folders.containsKey(fid)) return;
    final now = service.nowMs;
    final toRemove = [for (final r in checked) if (!pick.selected.contains(r)) r];
    final toAdd = [
      for (final r in rows)
        if (!checked.contains(r.ref) && pick.selected.contains(r.ref)) r.ref,
    ];
    var next = cur.state;
    if (toRemove.isNotEmpty) next = folderRemove(next, fid, toRemove, now).state;
    if (toAdd.isNotEmpty) {
      final r = folderAdd(next, fid, toAdd, now);
      if (r.error != null) {
        folderError(r.error);
        selection = Set.of(pick.selected);
        continue;
      }
      next = r.state;
    }
    if (!identical(next, cur.state)) cur.commit(next);
    return;
  }
}

class FolderPickerDialog extends ConsumerStatefulWidget {
  const FolderPickerDialog({super.key, required this.rows});

  final List<FolderPickRow> rows;

  @override
  ConsumerState<FolderPickerDialog> createState() => _FolderPickerDialogState();
}

class _FolderPickerDialogState extends ConsumerState<FolderPickerDialog> {
  final TextEditingController _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final pick = ref.watch(sidebarFolderPickerProvider);
    final selected = pick?.selected ?? const <String>{};
    final q = (pick?.query ?? '').trim().toLowerCase();
    final full = selected.length >= FoldersLimits.perFolder;
    final shown = q.isEmpty
        ? widget.rows
        : [for (final r in widget.rows) if (r.label.toLowerCase().contains(q)) r];
    final title = tr(FoldersStrings.addChats);
    return Dialog(
      key: const ValueKey('sbFolderPicker'),
      backgroundColor: c.bgSecondary,
      insetPadding: const EdgeInsets.all(16),
      shape: RoundedRectangleBorder(
        borderRadius: NymRadius.rmd,
        side: BorderSide(color: c.glassBorder),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440, maxHeight: 640),
        child: Semantics(
          scopesRoute: true,
          namesRoute: true,
          explicitChildNodes: true,
          label: title,
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.escape): () =>
                  Navigator.of(context).pop(false),
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 8, 6),
                  child: Row(
                    children: [
                      Expanded(
                        child: Semantics(
                          header: true,
                          child: Text(title,
                              style: TextStyle(
                                  color: c.text,
                                  fontSize: NymType.lg,
                                  fontWeight: FontWeight.w600)),
                        ),
                      ),
                      IconButton(
                        tooltip: tr(FoldersStrings.cancel),
                        constraints:
                            const BoxConstraints(minWidth: 44, minHeight: 44),
                        onPressed: () => Navigator.of(context).pop(false),
                        icon: NymSvgIcon(NymIcons.close, size: 16, color: c.textDim),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: TextField(
                    key: const ValueKey('sbFolderPickerSearch'),
                    controller: _ctrl,
                    autofocus: true,
                    style: TextStyle(color: c.inputText, fontSize: 14),
                    onChanged: (v) =>
                        ref.read(sidebarFolderPickerProvider.notifier).search(v),
                    decoration: NymField.decoration(c,
                        hint: tr(FoldersStrings.searchChats),
                        fontSize: 14,
                        radius: NymRadius.rxs,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 10)),
                  ),
                ),
                if (full)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: Text(
                      tr(FoldersStrings.capItems, {'n': FoldersLimits.perFolder}),
                      style: TextStyle(color: c.textDim, fontSize: NymType.sm),
                    ),
                  ),
                Flexible(
                  child: shown.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(tr(FoldersStrings.empty),
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  color: c.textDim, fontSize: NymType.sm)),
                        )
                      : ListView(
                          shrinkWrap: true,
                          padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                          children: [
                            for (final r in shown)
                              _FolderPickRowTile(
                                key: ValueKey('sbPick-${r.ref}'),
                                row: r,
                                checked: selected.contains(r.ref),
                                enabled: selected.contains(r.ref) || !full,
                              ),
                          ],
                        ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        key: const ValueKey('sbFolderPickerCancel'),
                        style: TextButton.styleFrom(
                            minimumSize: const Size(44, 44),
                            foregroundColor: c.textDim),
                        onPressed: () => Navigator.of(context).pop(false),
                        child: Text(tr(FoldersStrings.cancel)),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        key: const ValueKey('sbFolderPickerDone'),
                        style: FilledButton.styleFrom(
                            minimumSize: const Size(44, 44),
                            backgroundColor: c.primary,
                            foregroundColor: c.isLight ? Colors.white : Colors.black),
                        onPressed: () => Navigator.of(context).pop(true),
                        child: Text(tr(FoldersStrings.done)),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FolderPickRowTile extends ConsumerWidget {
  const _FolderPickRowTile(
      {super.key, required this.row, required this.checked, required this.enabled});

  final FolderPickRow row;
  final bool checked;
  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.nym;
    void toggle() => ref
        .read(sidebarFolderPickerProvider.notifier)
        .toggle(row.ref, canAdd: enabled);
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: MergeSemantics(
        child: InkWell(
          borderRadius: NymRadius.rxs,
          hoverColor: c.primary.withValues(alpha: 0.08),
          onTap: enabled ? toggle : null,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                children: [
                  SizedBox(
                    width: 24,
                    height: 24,
                    child: Checkbox(
                      value: checked,
                      activeColor: c.primary,
                      onChanged: enabled ? (_) => toggle() : null,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(row.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: c.text, fontSize: 14)),
                  ),
                  if (row.other.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        tr(FoldersStrings.inFolder, {'folder': row.other}),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: c.textDim, fontSize: NymType.sm),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
