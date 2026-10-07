import 'package:flutter/widgets.dart';

class HollowBullet extends StatelessWidget {
  const HollowBullet({
    super.key,
    required this.color,
    required this.fontSize,
    this.lineHeight = 1.0,
  });

  final Color color;
  final double fontSize;
  final double lineHeight;

  @override
  Widget build(BuildContext context) {
    final d = (fontSize * 0.34).clamp(4.0, 8.0);
    return SizedBox(
      width: fontSize * 0.6,
      height: fontSize * lineHeight,
      child: Center(
        child: Container(
          width: d,
          height: d,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: color, width: 1),
          ),
        ),
      ),
    );
  }
}
