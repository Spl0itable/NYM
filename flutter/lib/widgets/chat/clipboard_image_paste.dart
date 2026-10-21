import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

class PastedImage {
  const PastedImage(this.bytes, this.mimeType);

  final Uint8List bytes;
  final String mimeType;

  static const mimeTypes = <String>[
    'image/png',
    'image/jpeg',
    'image/jpg',
    'image/gif',
    'image/webp',
  ];

  static PastedImage? from(Object? bytes, Object? mimeType) {
    if (bytes is! Uint8List || bytes.isEmpty) return null;
    if (mimeType is! String) return null;
    final type = mimeType.toLowerCase().trim();
    if (!mimeTypes.contains(type)) return null;
    return PastedImage(bytes, type == 'image/jpg' ? 'image/jpeg' : type);
  }

  String get fileName {
    final sub = mimeType.substring('image/'.length);
    return 'pasted-image.${sub == 'jpeg' ? 'jpg' : sub}';
  }

  XFile get file => XFile.fromData(bytes, mimeType: mimeType, name: fileName);
}

class ClipboardImage {
  static const channel = MethodChannel('app.nymchat/clipboard');

  static Future<bool> available() async {
    try {
      return await channel.invokeMethod<bool>('hasImage') == true;
    } catch (_) {
      return false;
    }
  }

  static Future<PastedImage?> read({required int limit}) async {
    try {
      final found = await channel
          .invokeMapMethod<String, Object?>('readImage', {'limit': limit});
      if (found == null) return null;
      return PastedImage.from(found['bytes'], found['mimeType']);
    } catch (_) {
      return null;
    }
  }
}

class PasteClipboardIntent extends Intent {
  const PasteClipboardIntent();
}

class ImagePasteScope extends StatelessWidget {
  const ImagePasteScope({
    super.key,
    required this.limit,
    required this.onImage,
    required this.child,
  });

  final int limit;
  final ValueChanged<PastedImage> onImage;
  final Widget child;

  static ContentInsertionConfiguration keyboardInsertion(
          ValueChanged<PastedImage> onImage) =>
      ContentInsertionConfiguration(
        allowedMimeTypes: PastedImage.mimeTypes,
        onContentInserted: (content) {
          final image = PastedImage.from(content.data, content.mimeType);
          if (image != null) onImage(image);
        },
      );

  static Widget contextMenu(
    BuildContext context,
    EditableTextState editableTextState, {
    required int limit,
    required ValueChanged<PastedImage> onImage,
  }) =>
      _ImagePasteMenu(
          editableTextState: editableTextState, limit: limit, onImage: onImage);

  Future<void> _paste() async {
    if (await ClipboardImage.available()) {
      final image = await ClipboardImage.read(limit: limit);
      if (image != null) {
        onImage(image);
        return;
      }
    }
    final target = primaryFocus?.context;
    if (target != null && target.mounted) {
      Actions.maybeInvoke(
          target, const PasteTextIntent(SelectionChangedCause.keyboard));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.keyV, control: true):
            PasteClipboardIntent(),
        SingleActivator(LogicalKeyboardKey.keyV, meta: true):
            PasteClipboardIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          PasteClipboardIntent: CallbackAction<PasteClipboardIntent>(
            onInvoke: (_) {
              unawaited(_paste());
              return null;
            },
          ),
        },
        child: child,
      ),
    );
  }
}

class _ImagePasteMenu extends StatefulWidget {
  const _ImagePasteMenu({
    required this.editableTextState,
    required this.limit,
    required this.onImage,
  });

  final EditableTextState editableTextState;
  final int limit;
  final ValueChanged<PastedImage> onImage;

  @override
  State<_ImagePasteMenu> createState() => _ImagePasteMenuState();
}

class _ImagePasteMenuState extends State<_ImagePasteMenu> {
  bool _image = false;

  @override
  void initState() {
    super.initState();
    ClipboardImage.available().then((found) {
      if (found && mounted) setState(() => _image = true);
    });
  }

  void _paste() {
    final state = widget.editableTextState;
    state.hideToolbar();
    unawaited(_pasteImage(state));
  }

  Future<void> _pasteImage(EditableTextState state) async {
    final image = await ClipboardImage.read(limit: widget.limit);
    if (image != null) {
      widget.onImage(image);
    } else if (state.mounted) {
      state.pasteText(SelectionChangedCause.toolbar);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.editableTextState;
    if (SystemContextMenu.isSupportedByField(state)) {
      final items = SystemContextMenu.getDefaultItems(state);
      if (_image) {
        final at = items.indexWhere((i) => i is IOSSystemContextMenuItemPaste);
        final paste = IOSSystemContextMenuItemCustom(
          title: MaterialLocalizations.of(context).pasteButtonLabel,
          onPressed: _paste,
        );
        if (at >= 0) {
          items[at] = paste;
        } else {
          items.add(paste);
        }
      }
      return SystemContextMenu.editableText(
          editableTextState: state, items: items);
    }
    final items = List<ContextMenuButtonItem>.of(state.contextMenuButtonItems);
    if (_image) {
      final paste = ContextMenuButtonItem(
        type: ContextMenuButtonType.paste,
        onPressed: _paste,
      );
      final at = items.indexWhere((i) => i.type == ContextMenuButtonType.paste);
      if (at >= 0) {
        items[at] = paste;
      } else {
        final all =
            items.indexWhere((i) => i.type == ContextMenuButtonType.selectAll);
        items.insert(all >= 0 ? all : items.length, paste);
      }
    }
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: state.contextMenuAnchors,
      buttonItems: items,
    );
  }
}
