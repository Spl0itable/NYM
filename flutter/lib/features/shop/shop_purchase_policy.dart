import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;

/// iOS doesn't sell (App Store 3.1.1): it shows a plain statement, and adding any tap target there would break compliance.
bool get shopPurchasesDisabled {
  if (kIsWeb) return false;
  try {
    return Platform.isIOS;
  } catch (_) {
    return false;
  }
}

/// Same answer as [shopPurchasesDisabled]; separate so each surface can change independently.
bool get botCreditPurchasesDisabled => shopPurchasesDisabled;
