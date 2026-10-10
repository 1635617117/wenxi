// Pure-Dart no-op stub of the `tray_manager` plugin (and its re-exported
// menu_base Menu/MenuItem types), exposed under the same package/import name so
// main.dart compiles unchanged on iOS/Android, which have no system tray.
//
// Resolved via dependency_overrides on mobile builds only; desktop keeps the
// genuine plugin. Every call is inert and listeners are never invoked.

class MenuItem {
  MenuItem({this.key, this.label, this.type, this.checked, this.enabled});
  MenuItem.separator() : key = null, label = null, type = 'separator', checked = null, enabled = null;

  final String? key;
  final String? label;
  final String? type;
  final bool? checked;
  final bool? enabled;
}

class Menu {
  Menu({this.items = const <MenuItem>[]});
  final List<MenuItem> items;
}

/// No-op listener mixin. main.dart declares `with ... TrayListener` and
/// overrides onTrayIconMouseDown / onTrayIconRightMouseDown / onTrayMenuItemClick,
/// so those members must exist with matching signatures.
mixin TrayListener {
  void onTrayIconMouseDown() {}
  void onTrayIconMouseUp() {}
  void onTrayIconRightMouseDown() {}
  void onTrayIconRightMouseUp() {}
  void onTrayMenuItemClick(MenuItem menuItem) {}
}

class TrayManager {
  TrayManager._();
  static final TrayManager _instance = TrayManager._();
  static TrayManager get instance => _instance;

  Future<void> setIcon(String imagePath) async {}
  Future<void> setToolTip(String toolTip) async {}
  Future<void> setTitle(String title) async {}
  Future<void> setContextMenu(Menu value) async {}
  Future<void> popUpContextMenu() async {}
  Future<void> simulateTrayIconMouseDown() async {}
  Future<void> destroy() async {}

  void addListener(Object listener) {}
  void removeListener(Object listener) {}
}

final trayManager = TrayManager.instance;
