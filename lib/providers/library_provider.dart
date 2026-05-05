import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Invalidating this provider triggers the library screen to reload data.
final libraryProvider = Provider<Object>((ref) => Object());