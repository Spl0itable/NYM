import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../../core/theme/nym_colors.dart';
import '../i18n/i18n.dart';
import 'panic_purge.dart';
import 'panic_wipe.dart';

class DeleteAccountPlan {
  const DeleteAccountPlan({required this.usable, required this.blocked});

  final int usable;
  final int blocked;

  int get total => usable + blocked;
}

class DeleteAccountReport {
  const DeleteAccountReport({this.unremoved = 0, this.iCloudDeleted = 0});

  final int unremoved;
  final int iCloudDeleted;
}

final Random _gapRandom = Random.secure();

Duration deleteAccountGap() =>
    Duration(milliseconds: 1500 + _gapRandom.nextInt(2501));

class DeleteAccountRun {
  DeleteAccountRun({
    required this.purge,
    required this.wipe,
    Duration Function()? gap,
    Future<int> Function()? iCloud,
    this.marked,
  })  : gap = gap ?? deleteAccountGap,
        iCloud = iCloud ?? (() async => 0);

  final PanicIdentityPurge purge;
  final PanicWipe wipe;
  final Duration Function() gap;
  final Future<int> Function() iCloud;
  final Set<String> Function()? marked;

  Future<DeleteAccountReport> run({
    void Function(int done, int total)? onProgress,
    void Function(String status)? onStatus,
  }) async {
    var missed = 0;
    try {
      final out = await purge.oneByOne(gap: gap, onProgress: onProgress);
      missed = out.missed;
      final m = marked;
      if (m != null) {
        final got = m();
        missed += out.done.where((pk) => !got.contains(pk)).length;
      }
    } catch (_) {
      missed = purge.expected;
    }
    var deleted = 0;
    try {
      deleted = await iCloud();
    } catch (_) {}
    await wipe.wipe(onStatus: onStatus);
    return DeleteAccountReport(unremoved: missed, iCloudDeleted: deleted);
  }
}

String deleteAccountConfirmText(DeleteAccountPlan plan, {required bool iOS}) {
  final parts = <String>[
    if (plan.total > 1)
      tr('This covers all {n} identities saved on this device.',
          {'n': plan.total}),
    tr('On this device: your keys, messages, settings and post-quantum '
        'recovery code.'),
    tr('On our servers: your synced settings, profile, PM and group archive, '
        'Nymbot conversations, scheduled messages, our copy of your public '
        'posts, your Nymbot credits and purchase records, reports you filed, '
        'and the spam-filter and app-check records about you.'),
    if (plan.blocked == 1)
      tr("1 identity is locked or uses a signer that isn't connected, so its "
          "server data can't be deleted from here. Switch to it and delete it "
          'first, or continue to remove it from this device only.'),
    if (plan.blocked > 1)
      tr("{n} identities are locked or use a signer that isn't connected, so "
          "their server data can't be deleted from here. Switch to each one "
          'and delete it first, or continue to remove them from this device '
          'only.',
          {'n': plan.blocked}),
    tr('Other devices signed in to these identities will also be wiped the '
        'next time they connect.'),
    tr('Public relays: posts and messages you sent to Nostr relays are kept '
        "by the relay operators and can't be deleted by us."),
    if (iOS)
      tr('Key backups saved to iCloud from this device are deleted too. Other '
          'key backups in iCloud or Google Drive stay there. Delete them in '
          'that service if you no longer want them.')
    else
      tr('Key backups you saved to iCloud or Google Drive stay there. Delete '
          'them in that service if you no longer want them.'),
    tr('Any remaining Nymbot credits will be lost.'),
    tr('This cannot be undone.'),
  ];
  return parts.join('\n\n');
}

List<String> deleteAccountDoneLines(DeleteAccountReport report) => [
      if (report.unremoved == 0)
        tr('Your keys, messages and settings are gone from this device, and '
            'your account data is gone from our servers.')
      else if (report.unremoved == 1)
        tr('Your keys, messages and settings are gone from this device. Your '
            'account data is gone from our servers, except for 1 identity we '
            "couldn't reach.")
      else
        tr('Your keys, messages and settings are gone from this device. Your '
            'account data is gone from our servers, except for {n} '
            "identities we couldn't reach.",
            {'n': report.unremoved}),
      if (report.iCloudDeleted == 1)
        tr('1 key backup saved to iCloud from this device was deleted.')
      else if (report.iCloudDeleted > 1)
        tr('{n} key backups saved to iCloud from this device were deleted.',
            {'n': report.iCloudDeleted}),
      tr('Posts already on public relays stay there.'),
    ];

class DeleteAccountDone extends StatelessWidget {
  const DeleteAccountDone(
      {super.key, required this.report, required this.onDone});

  final DeleteAccountReport report;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Material(
      color: c.bg,
      child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Semantics(
                liveRegion: true,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      tr('Account data deleted'),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: c.textBright,
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    for (final line in deleteAccountDoneLines(report)) ...[
                      const SizedBox(height: 12),
                      Text(
                        line,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: c.text, fontSize: 14, height: 1.5),
                      ),
                    ],
                    const SizedBox(height: 20),
                    FilledButton(
                      key: const ValueKey('deleteAccountDone'),
                      style: FilledButton.styleFrom(
                        backgroundColor: c.primary,
                        foregroundColor: c.bg,
                        minimumSize: const Size(140, 44),
                      ),
                      onPressed: onDone,
                      child: Text(tr('Done')),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class DeleteAccountScreen extends StatefulWidget {
  const DeleteAccountScreen({super.key, required this.run, this.onDone});

  final DeleteAccountRun run;
  final VoidCallback? onDone;

  @override
  State<DeleteAccountScreen> createState() => _DeleteAccountScreenState();
}

class _DeleteAccountScreenState extends State<DeleteAccountScreen> {
  String _status = tr('Deleting your account data on our servers…');
  DeleteAccountReport? _report;

  @override
  void initState() {
    super.initState();
    unawaited(_go());
  }

  Future<void> _go() async {
    final report = await widget.run.run(
      onProgress: (done, total) {
        if (!mounted || total <= 1) return;
        setState(() => _status = tr(
            'Deleting account data on our servers: identity {i} of {n}…',
            {'i': done, 'n': total}));
      },
      onStatus: (_) {
        if (mounted) setState(() => _status = tr('Wiping this device…'));
      },
    );
    if (mounted) setState(() => _report = report);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final report = _report;
    return PopScope(
      canPop: false,
      child: report != null
          ? DeleteAccountDone(
              report: report, onDone: () => widget.onDone?.call())
          : Material(
              color: c.bg,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 28,
                        height: 28,
                        child: CircularProgressIndicator(
                            strokeWidth: 2.5, color: c.primary),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        _status,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: c.textBright, fontSize: 14),
                      ),
                    ],
                  ),
                ),
              ),
            ),
    );
  }
}
