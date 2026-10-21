import 'package:flutter/material.dart';

import '../../models/channel.dart';
import '../share/share_sheet.dart';
import '../share/share_target.dart';

/// Canonical PWA host for shared links; `app.nymchat.app` does not exist.
const String kNymchatShareHost = 'https://web.nymchat.app';

/// Share URL for a channel name or geohash as a `#<channel>` fragment; empty falls back to `nymchat`.
String buildChannelShareUrl(String channel, {String host = kNymchatShareHost}) {
  final ch = channel.isEmpty ? kDefaultChannel : channel;
  return '$host/#$ch';
}

String channelEntryShareUrl(ChannelEntry entry,
        {String host = kNymchatShareHost}) =>
    buildChannelShareUrl(entry.key, host: host);

class ShareChannelModal extends StatelessWidget {
  const ShareChannelModal({super.key, required this.channelKey});

  final String channelKey;

  static Future<void> open(BuildContext context, String channelKey) =>
      ShareSheet.show(context, ShareChannelModal(channelKey: channelKey));

  @override
  Widget build(BuildContext context) =>
      ShareSheetBody(target: ShareTarget.channel(channelKey));
}
