// Pure-Dart no-op stub of the `window_manager` plugin, exposed under the same
// package/import name so main-project source compiles unchanged on iOS/Android.
//
// The real plugin only ships Linux/macOS/Windows backends. Mobile builds resolve
// this stub via dependency_overrides; every window call becomes an inert default.
// Desktop builds never load this file (they keep the genuine plugin).
import 'dart:async';
import 'dart:ui' show Color, Offset, Rect, Size;

enum TitleBarStyle { normal, hidden, transparent }

/// Bit-flag "enum" mirroring the native ResizeEdge values. Kept as const
/// instances (not a Dart enum) so `.values` stays a List and `.name` a String,
/// matching every call site in the main project (pip handles, startResizing).
class ResizeEdge {
  const ResizeEdge(this.value, this.name);
  final int value;
  final String name;

  static const ResizeEdge top = ResizeEdge(1, 'top');
  static const ResizeEdge bottom = ResizeEdge(2, 'bottom');
  static const ResizeEdge left = ResizeEdge(4, 'left');
  static const ResizeEdge topLeft = ResizeEdge(5, 'topLeft');
  static const ResizeEdge bottomLeft = ResizeEdge(6, 'bottomLeft');
  static const ResizeEdge right = ResizeEdge(8, 'right');
  static const ResizeEdge topRight = ResizeEdge(9, 'topRight');
  static const ResizeEdge bottomRight = ResizeEdge(10, 'bottomRight');

  static const List<ResizeEdge> values = <ResizeEdge>[
    top,
    bottom,
    left,
    topLeft,
    bottomLeft,
    right,
    topRight,
    bottomRight,
  ];

  @override
  String toString() => name;
}

class WindowOptions {
  const WindowOptions({
    this.title,
    this.backgroundColor,
    this.fullscreen = false,
    this.center = false,
    this.skipTaskbar = false,
    this.alwaysOnTop = false,
    this.titleBarStyle,
    this.windowButtonVisibility,
    this.size,
    this.minimumSize,
    this.maximumSize,
  });
  final String? title;
  final Color? backgroundColor;
  final bool fullscreen;
  final bool center;
  final bool skipTaskbar;
  final bool alwaysOnTop;
  final TitleBarStyle? titleBarStyle;
  final bool? windowButtonVisibility;
  final Size? size;
  final Size? minimumSize;
  final Size? maximumSize;
}

/// No-op listener mixin; mobile never registers one, but the class is used as a
/// `with WindowListener` bound in main.dart so it must exist with these members.
mixin WindowListener {
  void onWindowClose() {}
  void onWindowFocus() {}
  void onWindowBlur() {}
  void onWindowIconified() {}
  void onWindowRestore() {}
  void onWindowMaximize() {}
  void onWindowUnmaximize() {}
  void onWindowMinimize() {}
  void onWindowRestoreFromMinimize() {}
  void onWindowResize() {}
  void onWindowMove() {}
  void onWindowEnterFullScreen() {}
  void onWindowLeaveFullScreen() {}
}

class WindowManager {
  WindowManager._();
  static final WindowManager _instance = WindowManager._();
  static WindowManager get instance => _instance;

  Future<void> ensureInitialized() async {}
  Future<void> initialize({WindowOptions options = const WindowOptions()}) async {}
  Future<void> dispose() async {}

  Future<void> waitUntilReadyToShow(
    WindowOptions options,
    Future<void> Function() callback,
  ) async {
    await callback();
  }

  Future<void> show() async {}
  Future<void> hide() async {}
  Future<void> close() async {}
  Future<void> focus() async {}
  Future<void> blur() async {}
  Future<void> destroy({bool switchFocusToWindowsOS = false}) async {}
  Future<void> minimize() async {}
  Future<void> unminimize() async {}
  Future<void> maximize() async {}
  Future<void> unmaximize() async {}
  Future<void> setFullScreen(bool isFullScreen) async {}
  Future<void> setPreventClose(bool isPreventClose) async {}
  Future<void> setAlwaysOnTop(bool alwaysOnTop) async {}
  Future<void> setMaximizable(bool maximizable) async {}
  Future<void> setResizable(bool resizable) async {}
  Future<void> setMinimumSize(Size size) async {}
  Future<void> setMaximumSize(Size size) async {}
  Future<void> setSize(Size size) async {}
  Future<void> setBounds(Rect bounds, {bool synchronous = false}) async {}
  Future<void> setCenter({bool synchronous = false}) async {}
  Future<void> setTitleBarStyle(
    TitleBarStyle titleBarStyle, {
    bool windowButtonVisibility = true,
  }) async {}
  Future<void> setAspectRatio(double aspectRatio) async {}
  Future<void> startDragging() async {}
  Future<void> startResizing(ResizeEdge resizeEdge) async {}

  Future<bool> isFullScreen() async => false;
  Future<bool> isMaximized() async => false;
  Future<bool> isMinimized() async => false;
  Future<bool> isVisible() async => true;
  Future<bool> isAlwaysOnTop() async => false;
  Future<bool> isMaximizable() async => true;
  Future<bool> isResizable() async => true;
  Future<bool> isMovable() async => true;
  Future<bool> isPreventClose() async => false;
  Future<bool> isSkipTaskbar() async => false;
  Future<Size> getSize() async => Size.zero;
  Future<Rect> getBounds() async => Rect.zero;
  Future<Offset> getPosition() async => Offset.zero;
  Future<double> getAspectRatio() async => 0;
  Future<String> getTitle() async => '';

  void addListener(Object listener) {}
  void removeListener(Object listener) {}
}

final windowManager = WindowManager.instance;
