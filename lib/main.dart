import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'screens/library_screen.dart';
import 'utils/app_strings.dart';
import 'widgets/theme.dart';

/// Entry point for the Pleasure Principle app.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (_isDesktopPlatform) {
    await windowManager.ensureInitialized();
    await windowManager.setMinimumSize(const Size(800, 600));

    const windowOptions = WindowOptions(
      titleBarStyle: TitleBarStyle.hidden,
      backgroundColor: AppTheme.background,
    );

    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }

  runApp(const ProviderScope(child: MyApp()));
}

/// Returns whether the current runtime platform supports desktop window APIs.
bool get _isDesktopPlatform {
  if (kIsWeb) {
    return false;
  }

  return switch (defaultTargetPlatform) {
    TargetPlatform.windows || TargetPlatform.linux || TargetPlatform.macOS => true,
    _ => false,
  };
}

/// Root application widget.
class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: AppStrings.appTitle,
      theme: AppTheme.crimsonInk,
      home: const LibraryScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}
