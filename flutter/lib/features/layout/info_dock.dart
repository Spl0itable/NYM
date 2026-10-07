import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/message.dart';
import '../../widgets/context_menu/context_menu_actions.dart';
import 'layout_model.dart';

class DockedInfo {
  const DockedInfo.group(this.groupId)
      : target = null,
        message = null,
        backToGroupId = null,
        onReact = null,
        onTranslateInline = null;

  const DockedInfo.user(CtxTarget this.target,
      {this.message,
      this.backToGroupId,
      this.onReact,
      this.onTranslateInline})
      : groupId = null;

  final String? groupId;
  final CtxTarget? target;
  final Message? message;
  final String? backToGroupId;
  final VoidCallback? onReact;
  final ValueChanged<String?>? onTranslateInline;

  bool get isGroup => groupId != null;

  String? get pubkey => target?.pubkey;
}

final infoDockProvider = StateProvider<DockedInfo?>((ref) => null);

class InfoDock {
  InfoDock._();

  static int _hosts = 0;

  static void attach() => _hosts++;

  static void detach() => _hosts = _hosts > 0 ? _hosts - 1 : 0;

  static bool get hosted => _hosts > 0;

  static bool canDock(BuildContext context) =>
      hosted &&
      infoPanelMode(MediaQuery.sizeOf(context).width) == 'docked';

  static bool tryDock(BuildContext context, DockedInfo info) {
    if (!canDock(context)) return false;
    ProviderScope.containerOf(context, listen: false)
        .read(infoDockProvider.notifier)
        .state = info;
    return true;
  }
}
