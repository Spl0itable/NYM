import 'package:flutter/widgets.dart';

class ChatCoveredScope extends InheritedWidget {
  const ChatCoveredScope({
    super.key,
    required this.covered,
    required super.child,
  });

  final bool covered;

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ChatCoveredScope>()?.covered ??
      false;

  @override
  bool updateShouldNotify(ChatCoveredScope oldWidget) =>
      oldWidget.covered != covered;
}
