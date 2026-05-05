import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:kamimashita/api/lanraragi_client.dart';
import 'package:kamimashita/main.dart';
import 'package:kamimashita/models/library_sort_option.dart';

void main() {
  test('date sort serializes to date_added', () {
    final params = ArchiveSearchOptions(
      sortBy: LibrarySortOption.date.apiValue,
    ).toQueryParameters();

    expect(params['sortby'], 'date_added');
  });

  test('title sort serializes to title', () {
    final params = ArchiveSearchOptions(
      sortBy: LibrarySortOption.title.apiValue,
    ).toQueryParameters();

    expect(params['sortby'], 'title');
  });

  test('namespace sort aliases parody to series', () {
    final option = LibrarySortOption.fromNamespace('parody');

    expect(option.label, 'Series');
    expect(option.apiValue, 'series');
  });

  test('namespace sort passes through artist', () {
    final params = ArchiveSearchOptions(
      sortBy: LibrarySortOption.fromNamespace('artist').apiValue,
    ).toQueryParameters();

    expect(params['sortby'], 'artist');
  });

  testWidgets('shows configuration prompt when no server is saved', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(const ProviderScope(child: MyApp()));
    await tester.pumpAndSettle();

    expect(find.text('No server configured'), findsOneWidget);
    expect(find.text('Configure'), findsOneWidget);
  });
}
