import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart' show AppleLogoPainter;

import '../../core/theme/nym_colors.dart';
import '../../features/i18n/i18n.dart';

const double brandGroupGap = 28;

const double brandPasskeyGap = 16;

double get brandButtonHeight =>
    defaultTargetPlatform == TargetPlatform.android ? 48 : 44;

class BrandButton extends StatelessWidget {
  const BrandButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
    required this.background,
    required this.foreground,
    this.border,
    this.gap = 12,
    this.busy = false,
  });

  final String label;
  final Widget icon;
  final VoidCallback? onPressed;
  final Color background;
  final Color foreground;
  final Color? border;
  final double gap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final shape = StadiumBorder(
      side: border == null ? BorderSide.none : BorderSide(color: border!),
    );
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      onTap: onPressed,
      excludeSemantics: true,
      child: Opacity(
        opacity: enabled || busy ? 1 : 0.5,
        child: Material(
          color: background,
          shape: shape,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onPressed,
            customBorder: shape,
            overlayColor: WidgetStateProperty.resolveWith((states) =>
                states.contains(WidgetState.pressed) ||
                        states.contains(WidgetState.hovered) ||
                        states.contains(WidgetState.focused)
                    ? foreground.withValues(alpha: 0.08)
                    : null),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: brandButtonHeight),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SizedBox(
                      width: 20,
                      height: 20,
                      child: busy
                          ? Padding(
                              padding: const EdgeInsets.all(2),
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: foreground),
                            )
                          : Center(child: icon),
                    ),
                    SizedBox(width: gap),
                    Flexible(
                      child: Text(
                        label,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: foreground,
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                          height: 1.2,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class AppleButton extends StatelessWidget {
  const AppleButton({super.key, required this.onPressed, this.busy = false});

  final VoidCallback? onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final dark = !context.nym.isLight;
    final background = dark ? Colors.white : Colors.black;
    final foreground = dark ? Colors.black : Colors.white;
    return BrandButton(
      label: tr('Continue with Apple'),
      icon: AppleMark(color: foreground),
      onPressed: onPressed,
      background: background,
      foreground: foreground,
      gap: 8,
      busy: busy,
    );
  }
}

class GoogleButton extends StatelessWidget {
  const GoogleButton({super.key, required this.onPressed, this.busy = false});

  final VoidCallback? onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final dark = !context.nym.isLight;
    return BrandButton(
      label: tr('Continue with Google'),
      icon: const GoogleMark(),
      onPressed: onPressed,
      background: dark ? const Color(0xFF131314) : const Color(0xFFFFFFFF),
      foreground: dark ? const Color(0xFFE3E3E3) : const Color(0xFF1F1F1F),
      border: dark ? const Color(0xFF8E918F) : const Color(0xFF747775),
      busy: busy,
    );
  }
}

class PasskeyButton extends StatelessWidget {
  const PasskeyButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.busy = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return BrandButton(
      label: label,
      icon: PasskeyMark(color: c.inputText),
      onPressed: onPressed,
      background: c.bgSecondary,
      foreground: c.inputText,
      border: c.textDim.withValues(alpha: 0.6),
      busy: busy,
    );
  }
}

class AppleMark extends StatelessWidget {
  const AppleMark({super.key, required this.color, this.size = 18});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: size * 0.82,
        height: size,
        child: CustomPaint(painter: AppleLogoPainter(color: color)),
      );
}

class GoogleMark extends StatelessWidget {
  const GoogleMark({super.key, this.size = 20});

  final double size;

  static const _parts = <(int, String)>[
    (0xFF4285F4, 'M22.56 12.25c0-.78-.07-1.53-.2-2.25H12v4.26h5.92c-.26 1.37-1.04 2.53-2.21 3.31v2.77h3.57c2.08-1.92 3.28-4.74 3.28-8.09z'),
    (0xFF34A853, 'M12 23c2.97 0 5.46-.98 7.28-2.66l-3.57-2.77c-.98.66-2.23 1.06-3.71 1.06-2.86 0-5.29-1.93-6.16-4.53H2.18v2.84C3.99 20.53 7.7 23 12 23z'),
    (0xFFFBBC05, 'M5.84 14.09c-.22-.66-.35-1.36-.35-2.09s.13-1.43.35-2.09V7.07H2.18C1.43 8.55 1 10.22 1 12s.43 3.45 1.18 4.93l2.85-2.22.81-.62z'),
    (0xFFEA4335, 'M12 5.38c1.62 0 3.06.56 4.21 1.64l3.15-3.15C17.45 2.09 14.97 1 12 1 7.7 1 3.99 3.47 2.18 7.07l3.66 2.84c.87-2.6 3.3-4.53 6.16-4.53z'),
  ];

  static final List<(Color, ui.Path)> _geometry = [
    for (final (color, d) in _parts) (Color(color), _parsePath(d)),
  ];

  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size,
        child: CustomPaint(painter: _PathsPainter(_geometry, box: 24)),
      );
}

class PasskeyMark extends StatelessWidget {
  const PasskeyMark({super.key, required this.color, this.size = 20});

  final Color color;
  final double size;

  static final ui.Path _path = _parsePath(
      'M120-160v-112q0-34 17.5-62.5T184-378q62-31 126-46.5T440-440q20 0 40 1.5t40 4.5q-4 58 21 109.5t73 84.5v80H120ZM760-40l-60-60v-186q-44-13-72-49.5T600-420q0-58 41-99t99-41q58 0 99 41t41 99q0 45-25.5 80T790-290l50 50-60 60 60 60-80 80ZM440-480q-66 0-113-47t-47-113q0-66 47-113t113-47q66 0 113 47t47 113q0 66-47 113t-113 47Zm300-80q17 0 28.5-11.5T780-600q0-17-11.5-28.5T740-640q-17 0-28.5 11.5T700-600q0 17 11.5 28.5T740-560Z');

  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size,
        child: CustomPaint(
          painter: _PathsPainter([(color, _path)], box: 960, top: -960),
        ),
      );
}

class _PathsPainter extends CustomPainter {
  _PathsPainter(this.paths, {required this.box, this.top = 0});

  final List<(Color, ui.Path)> paths;
  final double box;
  final double top;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / box, size.height / box);
    canvas.translate(0, -top);
    for (final (color, path) in paths) {
      canvas.drawPath(path, Paint()..color = color);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_PathsPainter old) =>
      old.box != box ||
      old.top != top ||
      old.paths.length != paths.length ||
      [for (var i = 0; i < paths.length; i++) paths[i].$1 != old.paths[i].$1]
          .any((changed) => changed);
}

ui.Path _parsePath(String d) {
  final tokens = RegExp(r'[A-Za-z]|-?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?')
      .allMatches(d)
      .map((m) => m.group(0)!)
      .toList();
  final path = ui.Path();
  var i = 0;
  var command = '';
  var x = 0.0, y = 0.0, startX = 0.0, startY = 0.0;
  var controlX = 0.0, controlY = 0.0;
  var lastQuad = false, lastCubic = false;
  bool isCommand(String token) => RegExp(r'^[A-Za-z]$').hasMatch(token);
  double next() => double.parse(tokens[i++]);
  while (i < tokens.length) {
    if (isCommand(tokens[i])) command = tokens[i++];
    final relative = command == command.toLowerCase();
    final ox = relative ? x : 0.0, oy = relative ? y : 0.0;
    var quad = false, cubic = false;
    switch (command.toUpperCase()) {
      case 'M':
        x = ox + next();
        y = oy + next();
        startX = x;
        startY = y;
        path.moveTo(x, y);
        command = relative ? 'l' : 'L';
      case 'L':
        x = ox + next();
        y = oy + next();
        path.lineTo(x, y);
      case 'H':
        x = ox + next();
        path.lineTo(x, y);
      case 'V':
        y = oy + next();
        path.lineTo(x, y);
      case 'C':
        final x1 = ox + next(), y1 = oy + next();
        controlX = ox + next();
        controlY = oy + next();
        x = ox + next();
        y = oy + next();
        path.cubicTo(x1, y1, controlX, controlY, x, y);
        cubic = true;
      case 'S':
        final x1 = lastCubic ? 2 * x - controlX : x;
        final y1 = lastCubic ? 2 * y - controlY : y;
        controlX = ox + next();
        controlY = oy + next();
        x = ox + next();
        y = oy + next();
        path.cubicTo(x1, y1, controlX, controlY, x, y);
        cubic = true;
      case 'Q':
        controlX = ox + next();
        controlY = oy + next();
        x = ox + next();
        y = oy + next();
        path.quadraticBezierTo(controlX, controlY, x, y);
        quad = true;
      case 'T':
        controlX = lastQuad ? 2 * x - controlX : x;
        controlY = lastQuad ? 2 * y - controlY : y;
        x = ox + next();
        y = oy + next();
        path.quadraticBezierTo(controlX, controlY, x, y);
        quad = true;
      case 'Z':
        path.close();
        x = startX;
        y = startY;
      default:
        return path;
    }
    lastQuad = quad;
    lastCubic = cubic;
  }
  return path;
}
