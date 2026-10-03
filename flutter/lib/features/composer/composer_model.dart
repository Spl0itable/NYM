class ComposerStrings {
  const ComposerStrings._();

  static const String meshOff = 'Not available over mesh';
  static const String meshPhoto = 'Up to 100 KB over mesh';
  static const String pollMesh =
      "Polls need the internet. They can't be created over the Bluetooth mesh.";
  static const String sendLater = 'Send later';
  static const String sendAnon = 'Send anonymously';

  static Map<String, String> toJson() => {
        'meshOff': meshOff,
        'meshPhoto': meshPhoto,
        'pollMesh': pollMesh,
        'sendLater': sendLater,
        'sendAnon': sendAnon,
      };

  static const List<String> ui = [
    'Attach',
    'Photo or video',
    'File',
    'Location',
    'Video note',
    'Poll',
    'Event',
    'Emoji and GIFs',
    'Emoji',
    'GIF',
    'More send options',
    'Send options',
    'Main menu',
    'Notifications',
    'Saved',
    'Calls',
    'Flair',
    'Settings',
    'About',
  ];
}

const List<String> kAttachOrder = [
  'photo',
  'file',
  'location',
  'videoNote',
  'poll',
  'event',
];

const double kComposerSheetMaxWidth = 768;

const bool kPrivatePollsEnabled = true;

class MainMenuItems {
  const MainMenuItems._();

  static const List<String> primary = ['notifications', 'saved', 'calls'];
  static const List<String> secondary = ['flair', 'settings', 'about'];

  static Map<String, List<String>> toJson() => {
        'primary': primary,
        'secondary': secondary,
      };
}

class RoundState {
  const RoundState(this.state, [this.reason = '']);

  static const RoundState ok = RoundState('ok');

  final String state;
  final String reason;
}

class AttachItem {
  const AttachItem(
    this.id, {
    this.enabled = true,
    this.reason = '',
    this.detail = '',
    this.warn = '',
  });

  final String id;
  final bool enabled;
  final String reason;
  final String detail;
  final String warn;

  String get note => enabled ? warn : reason;

  Map<String, Object> toJson() => {
        'id': id,
        'enabled': enabled,
        'reason': reason,
        'detail': detail,
        'warn': warn,
      };
}

bool pollAllowedOn(String surface,
        {bool bot = false, bool privatePolls = kPrivatePollsEnabled}) =>
    surface == 'channel' || (privatePolls && !(surface == 'dm' && bot));

List<AttachItem> attachItems({
  String surface = 'channel',
  String route = 'online',
  RoundState round = RoundState.ok,
  bool bot = false,
  bool privatePolls = kPrivatePollsEnabled,
}) {
  final mesh = route == 'mesh';
  AttachItem off(String id, String reason, [String? detail]) => AttachItem(id,
      enabled: false, reason: reason, detail: detail ?? reason);
  return [
    mesh
        ? const AttachItem('photo', warn: ComposerStrings.meshPhoto)
        : const AttachItem('photo'),
    mesh
        ? const AttachItem('file', warn: ComposerStrings.meshPhoto)
        : const AttachItem('file'),
    if (surface != 'channel') const AttachItem('location'),
    if (round.state == 'off')
      off('videoNote', mesh ? ComposerStrings.meshOff : round.reason,
          round.reason)
    else
      AttachItem('videoNote', warn: round.state == 'warn' ? round.reason : ''),
    if (pollAllowedOn(surface, bot: bot, privatePolls: privatePolls))
      mesh
          ? off('poll', ComposerStrings.meshOff, ComposerStrings.pollMesh)
          : const AttachItem('poll'),
    if (surface == 'group') const AttachItem('event'),
  ];
}

String primaryAction({
  String text = '',
  int attachments = 0,
  bool editing = false,
  bool busy = false,
  bool recording = false,
}) {
  if (recording) return 'mic';
  if (editing || busy) return 'send';
  if (attachments > 0) return 'send';
  return text.trim().isNotEmpty ? 'send' : 'mic';
}

class SendMenuItem {
  const SendMenuItem(this.id, this.label);

  final String id;
  final String label;

  Map<String, String> toJson() => {'id': id, 'label': label};
}

List<SendMenuItem> sendMenuItems({bool canAnon = false}) => [
      const SendMenuItem('later', ComposerStrings.sendLater),
      if (canAnon) const SendMenuItem('anon', ComposerStrings.sendAnon),
    ];

String menuPresentation(double width) =>
    width <= kComposerSheetMaxWidth ? 'sheet' : 'popover';

int menuStep(int count, int index, String key) {
  if (count == 0) return -1;
  switch (key) {
    case 'ArrowDown':
      return index < 0 ? 0 : (index + 1) % count;
    case 'ArrowUp':
      return index < 0 ? count - 1 : (index - 1 + count) % count;
    case 'Home':
      return 0;
    case 'End':
      return count - 1;
  }
  return -1;
}

bool isMenuKey(String key, {bool shift = false}) =>
    key == 'ContextMenu' || (key == 'F10' && shift);

class MainMenuRows {
  const MainMenuRows(this.grid);

  final List<List<String>> grid;

  Map<String, Object> toJson() => {'grid': grid};
}

MainMenuRows mainMenuRows([String layout = 'mobile']) =>
    const MainMenuRows([MainMenuItems.primary, MainMenuItems.secondary]);
