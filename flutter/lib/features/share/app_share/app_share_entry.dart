import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_share_sheet.dart';

Future<void> Function(BuildContext)? appShareLauncher(Ref ref) => openAppShare;
