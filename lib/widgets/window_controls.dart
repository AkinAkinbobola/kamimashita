import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../utils/app_lifecycle.dart';
import 'theme.dart';

class WindowControls extends StatelessWidget {
  const WindowControls({super.key, this.spacing = 4});

  final double spacing;

  @override
  Widget build(BuildContext context) {
    if (!desktopWindowControlsEnabled) {
      return const SizedBox.shrink();
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const _WindowControlButton(
          glyph: _MinimizeWindowGlyph(),
          hoverColor: AppTheme.surfaceRaised,
          onPressed: _minimizeWindow,
        ),
        SizedBox(width: spacing),
        const _MaximizeWindowControlButton(),
        SizedBox(width: spacing),
        const _WindowControlButton(
          icon: Icons.close,
          hoverColor: Color(0xFFE81123),
          onPressed: _closeWindow,
          hoverIconColor: Colors.white,
        ),
      ],
    );
  }
}

class _WindowControlButton extends StatefulWidget {
  const _WindowControlButton({
    required this.onPressed,
    required this.hoverColor,
    this.icon,
    this.glyph,
    this.hoverIconColor,
  });

  final IconData? icon;
  final Widget? glyph;
  final void Function() onPressed;
  final Color hoverColor;
  final Color? hoverIconColor;

  @override
  State<_WindowControlButton> createState() => _WindowControlButtonState();
}

class _WindowControlButtonState extends State<_WindowControlButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: () => widget.onPressed(),
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: 30,
          height: 28,
          decoration: BoxDecoration(
            color: _hovered ? widget.hoverColor : Colors.transparent,
          ),
          child: Center(
            child: IconTheme(
              data: IconThemeData(
                size: 14,
                color: _hovered
                    ? (widget.hoverIconColor ?? AppTheme.textPrimary)
                    : AppTheme.textSecondary,
              ),
              child: widget.glyph ?? Icon(widget.icon),
            ),
          ),
        ),
      ),
    );
  }
}

class _MaximizeWindowControlButton extends StatefulWidget {
  const _MaximizeWindowControlButton();

  @override
  State<_MaximizeWindowControlButton> createState() =>
      _MaximizeWindowControlButtonState();
}

class _MaximizeWindowControlButtonState
    extends State<_MaximizeWindowControlButton>
    with WindowListener {
  bool _isExpanded = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _syncWindowState();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowMaximize() {
    _setExpanded(true);
  }

  @override
  void onWindowUnmaximize() {
    _syncWindowState();
  }

  @override
  void onWindowEnterFullScreen() {
    _setExpanded(true);
  }

  @override
  void onWindowLeaveFullScreen() {
    _syncWindowState();
  }

  Future<void> _syncWindowState() async {
    final isExpanded =
        await windowManager.isFullScreen() || await windowManager.isMaximized();
    _setExpanded(isExpanded);
  }

  void _setExpanded(bool value) {
    if (!mounted || _isExpanded == value) {
      return;
    }
    setState(() {
      _isExpanded = value;
    });
  }

  Future<void> _handlePressed() async {
    await _toggleMaximizeWindow();
    await _syncWindowState();
  }

  @override
  Widget build(BuildContext context) {
    return _WindowControlButton(
      icon: _isExpanded
          ? Icons.filter_none_rounded
          : Icons.check_box_outline_blank_rounded,
      hoverColor: AppTheme.surfaceRaised,
      onPressed: _handlePressed,
    );
  }
}

class _MinimizeWindowGlyph extends StatelessWidget {
  const _MinimizeWindowGlyph();

  @override
  Widget build(BuildContext context) {
    final color = IconTheme.of(context).color ?? AppTheme.textSecondary;

    return Container(
      width: 10,
      height: 1.6,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(999),
      ),
    );
  }
}

bool get desktopWindowControlsEnabled {
  if (kIsWeb) {
    return false;
  }

  return switch (defaultTargetPlatform) {
    TargetPlatform.windows ||
    TargetPlatform.linux ||
    TargetPlatform.macOS => true,
    _ => false,
  };
}

Future<void> _minimizeWindow() async {
  await windowManager.minimize();
}

Future<void> _toggleMaximizeWindow() async {
  if (await windowManager.isMaximized()) {
    await windowManager.unmaximize();
    return;
  }

  await windowManager.maximize();
}

Future<void> _closeWindow() async {
  closeApp();
}
