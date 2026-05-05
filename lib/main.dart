import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'screens/library_screen.dart';
import 'widgets/theme.dart';

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

bool get _isDesktopPlatform {
  if (kIsWeb) {
    return false;
  }

  return switch (defaultTargetPlatform) {
    TargetPlatform.windows || TargetPlatform.linux || TargetPlatform.macOS => true,
    _ => false,
  };
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Pleasure Principle',
      theme: AppTheme.crimsonInk,
      home: const LibraryScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}
