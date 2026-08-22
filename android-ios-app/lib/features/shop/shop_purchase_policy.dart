import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;

/// Where flair can be bought from, per platform.
///
/// Apple does not allow an app to sell digital goods through anything but its
/// own in-app purchase, and the shop settles in sats over Lightning. Rather than
/// carry a whole store-billing integration for one platform — receipt
/// validation, a product tier ladder, console upkeep — the iOS build simply
/// does not sell: it shows the catalog, keeps everything an owner already has
/// working, and states where a purchase is made instead.
///
/// This is the shape reader apps use, and it is deliberately a STATEMENT, not a
/// call to action: no button, no tappable link, no price comparison. Apple's
/// 3.1.1 prohibits "buttons, external links, or other calls to action that
/// direct customers to purchasing mechanisms other than in-app purchase", and a
/// plain sentence is not one of those. Adding a tap target here would change
/// that, so don't.
///
/// Android is untouched — the Lightning invoice flow has passed Play review
/// repeatedly and continues to run in-app.
bool get shopPurchasesDisabled {
  if (kIsWeb) return false;
  try {
    return Platform.isIOS;
  } catch (_) {
    return false;
  }
}
