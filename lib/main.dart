import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'providers/settings_provider.dart';
import 'screens/library_screen.dart';
import 'utils/app_strings.dart';
import 'widgets/theme.dart';

Process? _kamaDlProcess;

/// Entry point for the Kamimashita app.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (_isDesktopPlatform) {
    final windowListener = _AppWindowListener();
    await windowManager.ensureInitialized();
    await windowManager.setPreventClose(true);
    windowManager.addListener(windowListener);
    await windowManager.setMinimumSize(const Size(800, 600));

    const windowOptions = WindowOptions(
      titleBarStyle: TitleBarStyle.hidden,
      backgroundColor: AppTheme.background,
    );

    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
      await _startKamaDlIfConfigured();
    });
  }

  runApp(const ProviderScope(child: MyApp()));
}

Future<void> _startKamaDlIfConfigured() async {
  if (_kamaDlProcess != null) {
    return;
  }

  final settings = SettingsModel.instance;
  if (!settings.isLoaded) {
    await settings.addListenerFuture();
  }

  final contentFolderPath = settings.contentFolderPath.trim();
  if (contentFolderPath.isEmpty) {
    return;
  }

  final executableDirectory = File(Platform.resolvedExecutable).parent.path;
  final executablePath = '$executableDirectory${Platform.pathSeparator}kami-dl.exe';
  final executableFile = File(executablePath);
  if (!await executableFile.exists()) {
    return;
  }

  _kamaDlProcess = await Process.start(executablePath, [
    '--output',
    contentFolderPath,
  ]);
  _kamaDlProcess!.exitCode.whenComplete(() {
    _kamaDlProcess = null;
  });
}

Future<void> _stopKamaDlIfRunning() async {
  final process = _kamaDlProcess;
  if (process == null) {
    return;
  }

  process.kill();
  _kamaDlProcess = null;
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

class _AppWindowListener extends WindowListener {
  @override
  Future<void> onWindowClose() async {
    await _stopKamaDlIfRunning();
    await windowManager.destroy();
  }
}

extension on SettingsModel {
  Future<void> addListenerFuture() {
    if (isLoaded) {
      return Future<void>.value();
    }

    final completer = Completer<void>();
    late VoidCallback listener;
    listener = () {
      if (!isLoaded || completer.isCompleted) {
        return;
      }
      removeListener(listener);
      completer.complete();
    };
    addListener(listener);
    return completer.future;
  }
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
