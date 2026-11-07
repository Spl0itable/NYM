import 'dart:ui' show ImageFilter;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/app_state.dart';
import '../../state/settings_provider.dart';

bool blursPicturesFrom(WidgetRef ref, String pubkey) {
  final app = ref.read(appStateProvider);
  if (pubkey.isNotEmpty && pubkey == app.selfPubkey) return false;
  final setting = ref.read(settingsProvider.notifier).blurImages;
  if (setting == 'true') return true;
  if (setting == 'friends') return !app.isFriend(pubkey);
  return false;
}

Widget blurPicture(Widget child) =>
    ImageFiltered(imageFilter: ImageFilter.blur(sigmaX: 20, sigmaY: 20), child: child);
