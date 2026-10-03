import 'package:flutter/widgets.dart';

void closeMenuRoute(BuildContext menuContext) {
  if (!menuContext.mounted) return;
  final route = ModalRoute.of(menuContext);
  if (route == null || !route.isActive) return;
  final nav = Navigator.of(menuContext);
  if (route.isCurrent) {
    nav.pop();
  } else {
    nav.removeRoute(route);
  }
}

Future<void> openOverMenu(
  VoidCallback closeMenu,
  Future<bool?> Function() open,
) async {
  if (await open() == true) closeMenu();
}
