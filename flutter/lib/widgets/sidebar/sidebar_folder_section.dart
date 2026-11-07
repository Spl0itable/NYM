part of 'sidebar.dart';

Widget _folderMemoRow(Map<Key, (Object, Widget)> memo, Key key, Object sig,
    Widget Function() make) {
  final hit = memo[key];
  if (hit != null && hit.$1 == sig) return hit.$2;
  final w = AutomaticKeepAlive(
    key: ValueKey<Key>(key),
    child: RepaintBoundary(child: _KeptRow(child: make())),
  );
  memo[key] = (sig, w);
  return w;
}

Key _folderRowKey(String fid, Object item) {
  if (item is ChannelEntry) return ValueKey('folder-$fid-channel-${item.key}');
  final e = item as SidebarPmEntry;
  return e.group != null
      ? ValueKey('folder-$fid-group-${e.group!.id}')
      : ValueKey('folder-$fid-pm-${e.pm!.pubkey}');
}

class _FolderSection extends ConsumerStatefulWidget {
  const _FolderSection({
    super.key,
    required this.fid,
    required this.reorderMode,
    required this.canMoveUp,
    required this.canMoveDown,
    required this.onMove,
    required this.onHold,
    required this.textSize,
    required this.i18n,
    required this.selfPubkey,
    required this.select,
    required this.onItemSelected,
  });

  final String fid;
  final bool reorderMode;
  final bool canMoveUp;
  final bool canMoveDown;
  final void Function(int delta) onMove;
  final VoidCallback onHold;
  final double textSize;
  final int i18n;
  final String selfPubkey;
  final void Function(ChatView) select;
  final VoidCallback? onItemSelected;

  @override
  ConsumerState<_FolderSection> createState() => _FolderSectionState();
}

class _FolderSectionState extends ConsumerState<_FolderSection> {
  final Map<Key, (Object, Widget)> _memo = {};
  final GlobalKey _menuKey = GlobalKey();

  String get fid => widget.fid;

  void _toggle() => ref.read(sidebarFoldersProvider).toggleCollapsed(fid);

  void _menu() {
    final box = _menuKey.currentContext?.findRenderObject() as RenderBox?;
    final at = box != null && box.hasSize
        ? box.localToGlobal(box.size.bottomCenter(Offset.zero))
        : Offset.zero;
    unawaited(folderMenu(context, ref, fid, at));
  }

  Widget _row(SidebarRow<Object> row) {
    final item = row.item;
    final key = _folderRowKey(fid, item);
    final textSize = widget.textSize;
    final i18n = widget.i18n;
    if (item is ChannelEntry) {
      final s = row.sig as SidebarChannelSig;
      return _folderMemoRow(
        _memo,
        key,
        (s, textSize, i18n),
        () => ChannelListItem(
          key: key,
          entry: item,
          active: s.active,
          pinned: s.pinned,
          unread: s.unread,
          textSize: textSize,
          reorder: false,
          onTap: () => widget.select(ChatView.channel(item.key)),
        ),
      );
    }
    final e = item as SidebarPmEntry;
    final g = e.group;
    if (g != null) {
      return _folderMemoRow(
        _memo,
        key,
        (row.sig, textSize, i18n),
        () => _GroupListItem(
          key: key,
          group: g,
          active: e.active,
          unread: e.unread,
          textSize: textSize,
          selfPubkey: widget.selfPubkey,
          users: ref.read(usersProvider),
          reorder: false,
          onTap: () => widget.select(ChatView.group(g.id)),
        ),
      );
    }
    final pm = e.pm!;
    return _folderMemoRow(
      _memo,
      key,
      (row.sig, textSize, i18n),
      () => PMListItem(
        key: key,
        nym: pm.nym,
        pubkey: pm.pubkey,
        active: e.active,
        unread: e.unread,
        textSize: textSize,
        mesh: e.mesh,
        reorder: false,
        onTap: () => widget.select(ChatView.pm(pm.pubkey)),
      ),
    );
  }

  Widget _head(BuildContext context, WidgetRef ref) {
    final c = context.nym;
    final head = ref.watch(sidebarFolderSplitProvider.select((s) {
      final f = s.folders[fid];
      return f == null ? null : (f.name, f.unread, f.label);
    }));
    final closed =
        ref.watch(sidebarFolderCollapsedProvider.select((s) => s.contains(fid)));
    final name = head?.$1 ?? '';
    final unread = head?.$2 ?? 0;
    final label = unread > 0
        ? tr(FoldersStrings.headLabelUnread, {'name': name, 'n': head!.$3})
        : tr(FoldersStrings.headLabel, {'name': name});
    final big = context.largeTouchTargets;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 16, 12, 0),
      child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 0, 10),
          child: Row(
            children: [
              if (widget.reorderMode) ...[
                Semantics(
                  button: true,
                  enabled: widget.canMoveUp,
                  label: tr(FoldersStrings.moveUp),
                  child: _ReorderBtn(
                    svg: NymIcons.reorderUp,
                    enabled: widget.canMoveUp,
                    onTap: () => widget.onMove(-1),
                  ),
                ),
                const SizedBox(width: 3),
                Semantics(
                  button: true,
                  enabled: widget.canMoveDown,
                  label: tr(FoldersStrings.moveDown),
                  child: _ReorderBtn(
                    svg: NymIcons.reorderDown,
                    enabled: widget.canMoveDown,
                    onTap: () => widget.onMove(1),
                  ),
                ),
                const SizedBox(width: 6),
              ],
              Expanded(
                child: _NavTitleHold(
                  onHold: widget.onHold,
                  child: NymFocusable(
                  onActivate: _toggle,
                  label: label,
                  radius: NymRadius.rxs,
                  excludeChildSemantics: true,
                  child: Semantics(
                    container: true,
                    button: true,
                    header: true,
                    expanded: !closed,
                    label: label,
                    excludeSemantics: true,
                    child: GestureDetector(
                      key: ValueKey('folderHead-$fid'),
                      behavior: HitTestBehavior.opaque,
                      onTap: _toggle,
                      child: ConstrainedBox(
                        constraints: BoxConstraints(minHeight: big ? 44 : 32),
                        child: Row(
                          children: [
                            NymSvgIcon(FolderIcons.folder,
                                size: 14, color: c.textDim),
                            const SizedBox(width: 6),
                            Flexible(child: _NavTitleText(name)),
                            if (closed && unread > 0) ...[
                              const SizedBox(width: 4),
                              KeyedSubtree(
                                key: ValueKey('folderBadge-$fid'),
                                child: SidebarUnreadPill(count: unread),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                ),
              ),
              const SizedBox(width: 10),
              KeyedSubtree(
                key: _menuKey,
                child: Semantics(
                  button: true,
                  label: tr(FoldersStrings.options),
                  child: _MiniIcon(
                    key: ValueKey('folderMenu-$fid'),
                    svg: NymIcons.rowMenu,
                    tooltip: tr(FoldersStrings.options),
                    onTap: _menu,
                  ),
                ),
              ),
              SizedBox(width: big ? 12 : 10),
              _NavTitleHold(
                onHold: widget.onHold,
                child: _MiniIcon(
                  key: ValueKey('folderChevron-$fid'),
                  svg: closed ? NymIcons.chevronRight : NymIcons.chevronDown,
                  onTap: _toggle,
                  focusable: false,
                ),
              ),
            ],
          ),
        ),
    );
  }

  Widget _body(BuildContext context, WidgetRef ref) {
    final c = context.nym;
    final closed =
        ref.watch(sidebarFolderCollapsedProvider.select((s) => s.contains(fid)));
    if (closed) {
      _memo.clear();
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }
    final rows = ref.watch(sidebarFolderSplitProvider
            .select((s) => s.folders[fid]?.rows)) ??
        const SidebarRows<Object>([]);
    final list = rows.rows;
    final keys = <Key>[for (final r in list) _folderRowKey(fid, r.item)];
    final keep = keys.toSet();
    _memo.removeWhere((k, _) => !keep.contains(k));
    final index = <Key, int>{
      for (var i = 0; i < keys.length; i++) ValueKey<Key>(keys[i]): i,
    };
    final empty = list.isEmpty;
    return SliverList(
      delegate: _RowsDelegate(
        count: empty ? 1 : list.length,
        index: index,
        childAt: (i) => empty
            ? Padding(
                key: ValueKey('folderEmpty-$fid'),
                padding: const EdgeInsets.fromLTRB(4, 2, 4, 2),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 32),
                  child: Row(
                    children: [
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.only(left: 12),
                          child: Text(tr(FoldersStrings.empty),
                              style: TextStyle(
                                  color: c.textDim, fontSize: NymType.sm)),
                        ),
                      ),
                      OutlinedButton(
                        key: ValueKey('folderAdd-$fid'),
                        style: OutlinedButton.styleFrom(
                          minimumSize: Size(10, context.largeTouchTargets ? 44 : 32),
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          foregroundColor: c.text,
                          side: BorderSide(color: c.glassBorder),
                          shape: const RoundedRectangleBorder(
                              borderRadius: NymRadius.rxs),
                          textStyle: const TextStyle(fontSize: NymType.sm),
                        ),
                        onPressed: () =>
                            unawaited(folderOpenPicker(context, ref, fid)),
                        child: Text(tr(FoldersStrings.addChats)),
                      ),
                    ],
                  ),
                ),
              )
            : _row(list[i]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return DecoratedSliver(
      key: ValueKey('folder-$fid'),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: c.glassBorder))),
      sliver: SliverMainAxisGroup(
        slivers: [
          SliverToBoxAdapter(
              child: RepaintBoundary(child: _SidebarLive(builder: _head))),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 13),
            sliver: _SidebarLive(builder: _body),
          ),
        ],
      ),
    );
  }
}

class _NewFolderButton extends StatelessWidget {
  const _NewFolderButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final label = tr(FoldersStrings.newFolder);
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: Material(
        color: Colors.transparent,
        borderRadius: NymRadius.rsm,
        child: InkWell(
          key: const ValueKey('sidebarNewFolderBtn'),
          borderRadius: NymRadius.rsm,
          hoverColor: c.primary.withValues(alpha: 0.1),
          onTap: onTap,
          child: Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            alignment: Alignment.center,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                NymSvgIcon(NymIcons.plus, size: 16, color: c.textDim),
                const SizedBox(width: 6),
                Text(label,
                    style: TextStyle(
                        color: c.textDim,
                        fontSize: NymType.sm,
                        fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
