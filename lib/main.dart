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

const int _kamaDlPort = 8765;

/// Entry point for the Kamimashita app.
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
      await _startKamaDlIfConfigured();
    });
  }

  runApp(const ProviderScope(child: MyApp()));
}

Future<void> _startKamaDlIfConfigured() async {
  if (await _isKamiDlPortInUse()) {
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
  final executablePath =
      '$executableDirectory${Platform.pathSeparator}kami-dl.exe';
  final executableFile = File(executablePath);
  if (!await executableFile.exists()) {
    return;
  }

  final processArguments = [
    '--output',
    contentFolderPath,
  ];
  final nhentaiApiKey = settings.nhentaiApiKey.trim();
  if (nhentaiApiKey.isNotEmpty) {
    processArguments.addAll(['--api-key', nhentaiApiKey]);
  }

  await Process.start(
    executablePath,
    processArguments,
    mode: ProcessStartMode.detached,
  );
}

Future<bool> _isKamiDlPortInUse() async {
  Socket? socket;
  try {
    socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      _kamaDlPort,
      timeout: const Duration(milliseconds: 500),
    );
    return true;
  } on SocketException {
    return false;
  } on TimeoutException {
    return false;
  } finally {
    await socket?.close();
  }
}

/// Returns whether the current runtime platform supports desktop window APIs.
bool get _isDesktopPlatform {
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
