import '../../../state/nostr_controller.dart';
import '../../i18n/i18n.dart';
import 'key_backup_crypto.dart';

enum BackupPqRestore { none, alreadyHeld, linked, rejected }

Future<BackupPqRestore> restoreBackupPqCode(
  NostrController ctrl,
  BackupSecret restored, {
  Duration timeout = const Duration(seconds: 30),
  Duration poll = const Duration(milliseconds: 250),
}) async {
  final code = restored.pqCode;
  if (code == null || !isValidBackupPqCode(code)) return BackupPqRestore.none;
  var waited = Duration.zero;
  while (!ctrl.pqRootHeld && !ctrl.pqRootLinkNeeded && waited < timeout) {
    await Future<void>.delayed(poll);
    waited += poll;
  }
  if (ctrl.pqRootHeld && ctrl.pqRootCode == code) {
    return BackupPqRestore.alreadyHeld;
  }
  final ok = await ctrl.linkPqRootFromCode(code);
  if (ok) return BackupPqRestore.linked;
  ctrl.showSystemNotice(tr(
      'The post-quantum recovery code in your key backup does not match this '
      'account, so it was not used. You can paste the right nympq1… code in '
      'View or Edit Nym’s Details.'));
  return BackupPqRestore.rejected;
}
