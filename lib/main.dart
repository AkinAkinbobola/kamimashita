import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'widgets/theme.dart';
import 'screens/library_screen.dart';

void main() {
  runApp(const ProviderScope(child: MyApp()));
}

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Pleasure Principle',
      theme: AppTheme.clean,
      home: const LibraryScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}
