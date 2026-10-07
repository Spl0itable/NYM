import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final chatHeaderExtentProvider = StateProvider<double?>((ref) => null);

final composerRestExtentProvider = StateProvider<double?>((ref) => null);

const String kSidebarPencilSvg =
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 20h9"></path><path d="M16.5 3.5a2.12 2.12 0 0 1 3 3L7 19l-4 1 1-4Z"></path></svg>';

const String kSidebarCheckSvg =
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="20 6 9 17 4 12"></polyline></svg>';

class ReportExtent extends SingleChildRenderObjectWidget {
  const ReportExtent({super.key, required this.onExtent, super.child});

  final ValueChanged<double> onExtent;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderReportExtent(onExtent);

  @override
  void updateRenderObject(
          BuildContext context, RenderReportExtent renderObject) =>
      renderObject.onExtent = onExtent;
}

class RenderReportExtent extends RenderProxyBox {
  RenderReportExtent(this.onExtent);

  ValueChanged<double> onExtent;
  double? _last;

  @override
  void performLayout() {
    super.performLayout();
    final h = size.height;
    if (h == _last) return;
    _last = h;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (attached) onExtent(h);
    });
  }
}

const double kSidebarIcon = 20;

const double kSidebarGap = 8;

const double kSidebarRowMinH = 36;

const double kSidebarMenuInset = 1;

const double kSidebarMenuBox = 32;

const double kSidebarMenuReserve = 20;

const double kSidebarSubLine = 16;

double sidebarRowMenuHit() =>
    defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS
        ? 40
        : 32;
