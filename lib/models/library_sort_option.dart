class LibrarySortOption {
  const LibrarySortOption._({
    required this.id,
    required this.label,
    required this.apiValue,
  });

  final String id;
  final String label;
  final String apiValue;

  static const title = LibrarySortOption._(
    id: 'title',
    label: 'Title',
    apiValue: 'title',
  );

  static const date = LibrarySortOption._(
    id: 'date',
    label: 'Date',
    apiValue: 'date_added',
  );

  static const group = LibrarySortOption._(
    id: 'group',
    label: 'Group',
    apiValue: 'group',
  );

  static const publisher = LibrarySortOption._(
    id: 'publisher',
    label: 'Publisher',
    apiValue: 'publisher',
  );

  static const character = LibrarySortOption._(
    id: 'character',
    label: 'Character',
    apiValue: 'character',
  );

  static const artist = LibrarySortOption._(
    id: 'artist',
    label: 'Artist',
    apiValue: 'artist',
  );

  static const series = LibrarySortOption._(
    id: 'series',
    label: 'Series',
    apiValue: 'series',
  );

  static const rating = LibrarySortOption._(
    id: 'rating',
    label: 'Rating',
    apiValue: 'rating',
  );

  static const language = LibrarySortOption._(
    id: 'language',
    label: 'Language',
    apiValue: 'language',
  );

  static const category = LibrarySortOption._(
    id: 'category',
    label: 'Category',
    apiValue: 'category',
  );

  static const lastRead = LibrarySortOption._(
    id: 'lastread',
    label: 'Last read',
    apiValue: 'lastread',
  );

  static const defaultNamespaceSortOptions = [
    date,
    group,
    publisher,
    character,
    artist,
    series,
    rating,
    language,
    category,
  ];

  static final Map<String, int> defaultNamespaceSortOrder = {
    for (var index = 0; index < defaultNamespaceSortOptions.length; index += 1)
      defaultNamespaceSortOptions[index].id: index,
  };

  static const _knownOptions = [
    title,
    date,
    group,
    publisher,
    character,
    artist,
    series,
    rating,
    language,
    category,
    lastRead,
  ];

  static final Map<String, LibrarySortOption> _byId = {
    for (final option in _knownOptions) option.id: option,
  };

  static LibrarySortOption fromId(String id) {
    final normalizedId = id.trim().toLowerCase();
    return _byId[normalizedId] ?? fromNamespace(normalizedId);
  }

  static LibrarySortOption fromNamespace(String namespace) {
    final normalizedNamespace = namespace.trim().toLowerCase();
    return switch (normalizedNamespace) {
      'date' || 'date_added' => date,
      'parody' || 'series' => series,
      'title' => title,
      'lastread' => lastRead,
      'group' => group,
      'publisher' => publisher,
      'character' => character,
      'artist' => artist,
      'rating' => rating,
      'language' => language,
      'category' => category,
      _ => LibrarySortOption._(
          id: normalizedNamespace,
          label: _formatLabel(normalizedNamespace),
          apiValue: normalizedNamespace,
        ),
    };
  }

  static String _formatLabel(String value) {
    return value
        .split('_')
        .where((part) => part.isNotEmpty)
        .map((part) => part[0].toUpperCase() + part.substring(1))
        .join(' ');
  }
}