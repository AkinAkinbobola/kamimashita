# Kamimashita Architecture

This document explains how the app works from top to bottom. It is written for a developer who already knows the repository and wants a reliable mental model for explaining or changing any part of it.

## 1. App Overview

Kamimashita is a Flutter app for browsing a LANraragi library, opening an archive, and reading its pages with desktop-friendly controls.

LANraragi is a self-hosted server for managing and reading manga, doujinshi, and other image-based archives.

The app connects to LANraragi over HTTP using the server URL and API key entered in settings. Once connected, it uses the LANraragi API to:

- load library results
- fetch archive details
- fetch page image URLs
- read and edit categories
- sync reading progress
- fetch tag statistics for search suggestions

At a high level, the app is a thin client. Most real content lives on the LANraragi server, while the app is responsible for presentation, local preferences, and a local fallback for in-progress reading history when server-side progress tracking is unavailable.

## 2. Architecture Overview

The code is split into a small number of layers.

### UI layer

The UI lives mainly in `lib/screens/` and `lib/widgets/`.

- `library_screen.dart` is the main browsing screen.
- `reader_screen.dart` is the reading experience.
- `settings_screen.dart` is the server connection form.
- `cover_card.dart` and a few private widgets inside the screen files handle reusable visual pieces.

The UI is stateful in the normal Flutter sense: screens keep their own transient UI state such as loading flags, selected items, search text, popovers, hover state, and scroll positions.

### State management layer

The app uses Riverpod, but in a very light way.

There are only a few providers, and most of the real data is held inside singleton `ChangeNotifier` objects:

- `SettingsModel.instance` stores connection settings, reader preferences, and local On Deck fallback data.
- `LibraryState.instance` stores the currently loaded library items, On Deck entries, and the last known archive count.
- `lanraragiClientProvider` creates a `LanraragiClient` from the current saved settings when the connection is valid.

This means the app is not built around a large reactive state graph. Instead, it mixes:

- `ChangeNotifier` singletons for shared state
- Riverpod providers as access points and refresh triggers
- local widget state for screen-specific behavior

### API layer

`lib/api/lanraragi_client.dart` wraps every LANraragi call used by the app. It is the only place that should know about raw endpoint paths, headers, timeout behavior, or inconsistent response formats.

It also contains small API-facing data classes such as:

- `ArchivePage`
- `ArchiveSearchOptions`
- `LanraragiCategory`
- `LanraragiTagStat`
- `LanraragiException`

### Model layer

The core domain model is `Archive` in `lib/models/archive.dart`.

There is also a sort-option model in `lib/models/library_sort_option.dart`.

One important detail: `OnDeckEntry` is not in `lib/models/`. It lives inside `settings_provider.dart` because it is treated as local persisted app state rather than a direct server model.

### Persistence layer

`lib/services/settings_storage_service.dart` handles local storage.

- `SharedPreferences` stores non-sensitive values such as server URL, reader preferences, and cached local On Deck entries.
- `FlutterSecureStorage` stores the API key.

### How the layers relate

In normal use, the flow looks like this:

1. `main.dart` starts the app and shows `LibraryScreen`.
2. `SettingsModel` loads persisted settings in the background.
3. `LibraryScreen` reacts to those settings and, if the connection is valid, loads categories, On Deck entries, and archive results.
4. When the user opens an archive, `ReaderScreen` uses `LanraragiClient` to fetch full archive data and page URLs.
5. Reader progress is synced back to the server when possible, and mirrored into the local On Deck cache.

## 3. Entry Point

The app starts in `lib/main.dart`.

### `main()`

`main()` does four things:

1. calls `WidgetsFlutterBinding.ensureInitialized()`
2. if the app is running on desktop, initializes `window_manager`
3. sets a minimum desktop window size of `800 x 600`
4. runs the app inside a Riverpod `ProviderScope`

Desktop startup also configures:

- hidden title bar styling
- custom background color from `AppTheme.background`
- `show()` and `focus()` once the window is ready

### `MyApp`

`MyApp` is a small `StatelessWidget` that builds a `MaterialApp` with:

- title from `AppStrings.appTitle`
- theme from `AppTheme.crimsonInk`
- `LibraryScreen` as `home`
- debug banner disabled

### Initial routing

There is no route table and no named-router setup. The app always starts on `LibraryScreen`, and every other screen is opened with `Navigator.push` and a `MaterialPageRoute`.

That means the launch path is simple:

`main()` -> `ProviderScope` -> `MyApp` -> `MaterialApp(home: LibraryScreen)`

## 4. State Management

This section lists every provider and the shared state objects behind them.

### `SettingsModel` in `lib/providers/settings_provider.dart`

`SettingsModel` is a singleton `ChangeNotifier`. It is the central storage for configuration and reader preferences.

It holds:

- `serverUrl`: LANraragi base URL
- `apiKey`: raw or encoded API key as last saved
- `cropThumbnails`: persisted but currently not used by the UI rendering path
- `readerFitMode`: saved fit mode string such as `contain` or `fitWidth`
- `readerContinuousScroll`: whether the reader uses scroll mode instead of page mode
- `readerRightToLeft`: whether reading direction is reversed
- `readerAutoHideChrome`: whether reader controls hide themselves after inactivity
- `readerFullscreen`: preferred fullscreen state for desktop reader sessions
- `onDeckEntries`: locally saved in-progress archive list
- `useLocalOnDeckFallback`: whether the app should stop trusting server progress and use local On Deck data instead
- `isLoaded`: whether persisted settings have finished loading

It exposes:

- `isValid`: true when both server URL and API key are present
- `authHeader()`: Authorization header map for LANraragi requests
- `update(...)`: updates and persists connection settings
- `updateReaderPreferences(...)`: updates and persists reader preferences
- `upsertOnDeckEntry(...)`: adds or updates a local in-progress entry
- `setUseLocalOnDeckFallback(bool)`: switches the app into or out of local On Deck mode
- `clear()`: resets everything and clears storage

Who uses it:

- `client_provider.dart` to decide whether a `LanraragiClient` can be created
- `LibraryScreen` to know whether it can load data and whether it should use local On Deck fallback
- `ReaderScreen` to load and save reader preferences and auth headers
- `SettingsScreen` to read and save connection info
- `ArchiveThumbnail` to build authenticated image requests

### `OnDeckEntry` in `lib/providers/settings_provider.dart`

`OnDeckEntry` represents a locally stored “continue reading” item.

It holds:

- `archiveId`
- `title`
- `currentPage`
- `totalPages`
- `updatedAt`

It exposes:

- `fromJson(...)`
- `fromArchive(...)`
- `toJson()`
- `isCompleted`

This model is used for the sidebar’s On Deck list and for local fallback when the server does not support progress tracking.

### `lanraragiClientProvider` in `lib/providers/client_provider.dart`

This is a plain Riverpod `Provider<LanraragiClient?>`.

It returns:

- a `LanraragiClient` built from the current settings when `SettingsModel.isValid` is true
- `null` otherwise

Who uses it:

- `ReaderScreen` uses it directly while loading a document

Most of the rest of the app constructs `LanraragiClient` directly from `SettingsModel.instance`, so this provider is not the only way the API client is accessed.

### `libraryProvider` in `lib/providers/library_provider.dart`

This provider does not hold data. It exists as an invalidation trigger.

`LibraryScreen` listens to it with `ref.listenManual(...)`. When other code calls `ref.invalidate(libraryProvider)`, the library screen reloads its current data.

This is used after actions that can change the visible library, such as category changes.

### `LibraryState` and `libraryStateProvider` in `lib/providers/library_provider.dart`

`LibraryState` is another singleton `ChangeNotifier`.

It holds:

- `_items`: the current loaded archive list
- `_onDeckEntries`: the current sidebar On Deck list
- `_lastKnownArchiveCount`: last known total archive count from the server

It exposes:

- `items`
- `onDeckEntries`
- `lastKnownArchiveCount`
- `setItems(...)`
- `clearItems()`
- `updateArchiveProgress(...)`
- `setOnDeckEntries(...)`
- `clearOnDeckEntries()`
- `upsertOnDeckEntry(...)`

Who uses it:

- `LibraryScreen` mirrors loaded library results into it and listens to it for external updates
- `ReaderScreen` updates archive progress and On Deck entries while reading

### Overall state pattern

The important thing to understand is that there are three kinds of state in this app:

1. persisted app state in `SettingsModel`
2. shared session state in `LibraryState`
3. screen-local UI state inside `LibraryScreen` and `ReaderScreen`

If you are changing behavior, it is worth deciding which bucket the change belongs in before writing code.

## 5. API Layer

All LANraragi API work lives in `lib/api/lanraragi_client.dart`.

### Client setup

`LanraragiClient` wraps a `Dio` instance with:

- a normalized base URL
- 15 second connect timeout
- 15 second receive timeout
- JSON `Accept` header

Base URL normalization removes:

- trailing `/`
- a trailing `/api` suffix if the user included it in settings

This lets users enter either the root server URL or the API URL without breaking requests.

### Authentication

LANraragi expects a bearer token, and this client handles two input cases:

- user enters a raw API key
- user enters an already base64-encoded API key

`normalizeApiKey()` checks whether the key already looks base64-encoded. If not, it encodes it.

`authorizationHeaders()` then returns:

`Authorization: Bearer <normalized-key>`

The client also has a retry path for `401` errors. If the saved key was not the same as its encoded form, it retries once with the explicitly encoded version.

### Error handling

Every public request method catches `DioException` and converts it into a `LanraragiException` with a user-facing message.

Examples:

- `401` -> authentication failed
- `404` -> endpoint not found, likely bad server URL
- timeout -> connection timed out
- connection error -> server unreachable
- JSON body with `error` -> surface the server-provided message

This is why most UI code just strips the `LanraragiException:` prefix and shows the rest of the text directly.

### Response normalization

LANraragi responses are not treated as perfectly consistent. The client includes helpers to:

- unwrap lists whether they are returned directly, under `results`, under `data`, or as the first list inside an object
- parse counts from multiple possible keys
- extract page URLs from multiple response shapes

That makes the rest of the app simpler, because screen code can work with clean Dart objects instead of raw JSON.

### Endpoints used by the app

#### Server info

- `GET /api/info`
- method: `getServerInfo()`
- used by: `SettingsScreen` to test a connection

#### Library search

- `GET /api/search`
- method: `fetchArchivePage(...)`
- used by: `LibraryScreen`

Query parameters include:

- `filter`
- `start`
- `category`
- `sortby`
- `order`
- `newonly`
- `untaggedonly`
- `hidecompleted`
- `groupby_tanks`

The method returns `ArchivePage`, which contains:

- `items`
- `recordsTotal`
- `recordsFiltered`
- `start`
- `nextStart`
- `hasMore`

#### Categories

- `GET /api/categories` -> `getCategories()`
- `PUT /api/categories` -> `createCategory(...)`
- `PUT /api/categories/{categoryId}` -> `updateCategory(...)`
- `DELETE /api/categories/{categoryId}` -> `deleteCategory(...)`
- `GET /api/archives/{archiveId}/categories` -> `getArchiveCategories(...)`
- `PUT /api/categories/{categoryId}/{archiveId}` -> `addArchiveToCategory(...)`
- `DELETE /api/categories/{categoryId}/{archiveId}` -> `removeArchiveFromCategory(...)`

The app sorts categories so pinned items appear first, then the rest alphabetically.

#### Tag statistics

- `GET /api/database/stats`
- methods: `getTagStats()` and `getArchiveCount()`

`getTagStats()` requests:

- `minweight=2`
- `hide_excluded_namespaces=true`

These statistics are used for search suggestions.

`getArchiveCount()` reads the same general stats payload but only extracts an archive count. `LibraryScreen` uses that number to cheaply detect whether the library changed while the window was unfocused.

#### On Deck and random archive

- On Deck is not a special LANraragi endpoint in this app
- method: `getOnDeckArchives()`

It simply calls the normal search endpoint with:

- `sortBy: lastread`
- `hideCompleted: true`

Random archive uses:

- `GET /api/search/random?count=1`
- method: `getRandomArchive()`

#### Single archive and progress

- `GET /api/archives/{archiveId}` -> `getArchive(...)`
- `PUT /api/archives/{archiveId}/progress/{page}` -> `updateArchiveProgress(...)`
- `DELETE /api/archives/{archiveId}/isnew` -> `clearArchiveIsNew(...)`

The reader uses these to fill missing archive fields, sync reading progress, and clear the “new” marker after opening a new archive.

#### Page image URLs

Page URL loading is more nuanced than the rest of the client.

`getPageUrls(...)` prefers two strategies:

1. If the app already knows the page count, it builds OPDS page URLs directly using:
   `/api/opds/{archiveId}/pse?page=<n>`
2. Otherwise it tries `GET /api/archives/{archiveId}/files` and extracts file names or URLs from the response.

If the file listing request fails but a page count is known, it still falls back to OPDS URLs.

This makes page loading more robust across LANraragi instances.

## 6. Models

### `Archive` in `lib/models/archive.dart`

`Archive` is the main server-side content model.

It represents one LANraragi archive and contains:

- `id`
- `title`
- `coverUrl`
- `filename`
- `sourceUrl`
- `tags`
- `progress`
- `lastReadTime`
- `isNew`
- `year`
- `pageCount`

Important derived properties and helpers:

- `isCompleted`: true when `progress >= pageCount`
- `thumbnailUrl(serverUrl)`: builds `/api/archives/{id}/thumbnail`
- `parsedTags`: splits the raw comma-separated tag string into trimmed tag values
- `copyWith(...)`: used when only progress changes

`Archive.fromJson(...)` is intentionally defensive. It reads several possible key names because LANraragi responses are not assumed to be perfectly stable.

It also derives `sourceUrl` from a `source:` tag if no explicit source field is present.

### `LibrarySortOption` in `lib/models/library_sort_option.dart`

This model represents the possible library sort choices shown in the toolbar.

It contains:

- `id`: internal stable identifier
- `label`: user-facing name
- `apiValue`: LANraragi query value

Built-in options include:

- title
- date
- group
- publisher
- character
- artist
- series
- rating
- language
- category
- lastRead

It also supports namespace-derived sort options from tag stats, so the sort menu can grow based on the data the server exposes.

### `OnDeckEntry`

Already covered in the state section, but conceptually it is the app’s local model for “continue reading” history.

### API-facing helper models in `lanraragi_client.dart`

These are not in `lib/models/`, but they matter architecturally.

#### `ArchiveSearchOptions`

Represents search filters and serializes them into query parameters.

#### `ArchivePage`

Represents one paginated search result page plus pagination metadata.

#### `LanraragiCategory`

Represents a category with:

- `id`
- `name`
- `pinned`
- `search`
- `archives`

Derived helpers:

- `isDynamic`
- `isStatic`

Dynamic categories are search-rule based. Static categories are manually managed archive lists.

#### `LanraragiTagStat`

Represents one weighted tag suggestion candidate with:

- `value`
- `weight`

#### `LanraragiException`

Simple wrapper for human-readable error messages.

## 7. Screens

### Library Screen

`lib/screens/library_screen.dart` is the app’s main workspace and by far the largest screen besides the reader.

It shows:

- the top bar with refresh and desktop window controls
- the left sidebar or drawer
- the search box
- the sort and filter toolbar
- the archive grid
- the archive details drawer when an item is selected

It reads shared state from:

- `SettingsModel`
- `LibraryState`

It also keeps a large amount of local UI state, including:

- current query text
- loaded archive items
- pagination state
- selected sort and sort order
- selected category
- boolean filters
- selected archive for the details drawer
- tag suggestion state
- category caches
- On Deck message state
- random pick state

Key behaviors:

#### Library loading

- initial load happens after first frame
- search reload resets the list and loads from page 0
- scrolling near the bottom triggers `_loadMore()`
- duplicate archive IDs are filtered out when appending pages

#### Background revalidation

When the desktop window regains focus, the screen waits briefly, checks the server archive count, and reloads in the background only if the count changed. This avoids unnecessary full refreshes every time the user alt-tabs back.

#### Search suggestions

Suggestions are built from two sources:

- weighted tag stats from the server
- terms extracted from loaded archive titles

The active token is the word around the cursor in the search box. Picking a suggestion rewrites only that token and appends an exact-match suffix `$` plus a comma separator.

#### Sort and filter toolbar

The toolbar lets the user change:

- sort field
- ascending or descending order
- static category filter
- dynamic category filter
- `new only`
- `untagged only`
- `hide completed`

`new only` and `untagged only` are treated as mutually exclusive when toggled from the filter menu.

#### Categories

The screen can:

- create categories
- edit categories
- delete categories
- assign a selected archive to a static category
- remove a selected archive from a category

After category changes it invalidates `libraryProvider`, which causes the current library view to reload.

#### Archive details drawer

Selecting a cover opens a right-side drawer that shows:

- larger thumbnail
- title
- page count
- current categories
- action to add to another static category
- source URL if available
- tags grouped by namespace
- `Read` button

Clicking a tag rewrites the search query to that exact tag and reloads the library.

#### On Deck sidebar

The sidebar shows recent in-progress entries.

It tries server-backed On Deck first by asking LANraragi for last-read, incomplete archives. If the app has switched to local fallback mode, it instead shows locally saved `OnDeckEntry` objects.

#### Random pick

The sidebar also has a random pick action. Instead of opening the reader immediately, it loads the archive into the details drawer so the user can inspect it first.

### Reader Screen

`lib/screens/reader_screen.dart` handles reading a single archive. Because it is the most complex screen, it has its own dedicated section later in this document.

At a high level it:

- loads full archive metadata if needed
- loads page URLs
- chooses an initial page
- shows either paged or continuous reading mode
- handles keyboard, mouse, trackpad, and touch-style pan/zoom input
- saves progress and local On Deck state
- exposes a reader settings popover

### Settings Screen

`lib/screens/settings_screen.dart` is intentionally narrow.

It shows:

- server URL field
- API key field
- `Test Connection` button
- `Save` button

Its flow is:

1. preload current values from `SettingsModel`
2. allow the user to test by calling `LanraragiClient.getServerInfo()`
3. refuse to save if the connection test fails
4. persist settings through `SettingsModel.update(...)`
5. pop back to the previous screen on success

Important limitation: this screen only edits connection settings. Reader preferences are changed inside the reader popover, not here.

## 8. Reader

The reader is the part of the app with the most moving parts.

### Reader startup

When `ReaderScreen` is created, it:

1. listens for settings changes
2. applies stored reader preferences once settings finish loading
3. starts `_loadDocument()`
4. sets up focus and timers after the first frame

`_loadDocument()` does the real work:

1. gets a `LanraragiClient` from `lanraragiClientProvider`
2. if the passed-in `Archive` is missing important fields, fetches the full archive from the server
3. fetches page URLs
4. resolves the initial page from explicit `initialPage` or saved server progress
5. builds authenticated `NetworkImage` providers for every page
6. recreates the page controller and page keys
7. clears the archive’s `isNew` flag on the server
8. records an On Deck entry immediately
9. prefetches nearby pages and syncs the viewport after first layout

The `_reloadToken` protects against stale async loads. If a reload happens mid-request, old results are discarded.

### Continuous mode vs paged mode

The reader supports two layouts.

#### Continuous mode

Continuous mode shows all pages in one vertical list.

Implementation details:

- uses the screen-level `_scrollController`
- uses `_pageKeys` so the app can scroll to a given page by widget position
- every page is rendered with `_ReaderPage(..., continuousLayout: true)`
- fit mode is effectively forced to `fitWidth` in continuous mode

Visible-page tracking is done by measuring each page widget against the viewport center. The page whose center is closest to the viewport center becomes the current page.

#### Paged mode

Paged mode uses a `PageView` where each page is still allowed to scroll vertically if the image is taller than the viewport.

Implementation details:

- uses `_pageController`
- page swiping is disabled with `NeverScrollableScrollPhysics`
- actual navigation is handled by custom logic from taps, wheel events, keys, or buttons
- each page owns its own vertical `ScrollController`

This split is important: page turning and within-page scrolling are different actions.

### Input handling

The reader accepts several forms of input.

#### Keyboard input

Handled in `_handleKeyEvent(...)` on the reader-level `Focus` widget.

Supported keys:

- `ArrowUp` and `ArrowDown`
  - in continuous mode: scroll the document
  - in paged mode: scroll within the current page
- `ArrowLeft` and `ArrowRight`
  - in paged mode: scroll within the current page
- `PageUp`
  - previous page in paged mode
- `PageDown`
  - next page in paged mode
- `A`
  - previous page in paged mode
- `D`
  - next page in paged mode
- `Space`
  - next page in paged mode
  - `Shift + Space` goes to previous page
- `M`
  - toggle controls visibility
- `F`
  - toggle fullscreen on supported desktop platforms
- `Escape`
  - dismiss end-of-archive card if open
  - else close the reader settings popover if open
  - else exit fullscreen if active
  - else leave the reader

#### Mouse wheel

In continuous mode:

- wheel scroll moves vertically
- `Ctrl + wheel` changes zoom
- desktop platforms use custom animated wheel scrolling instead of default list scrolling

In paged mode:

- wheel first scrolls inside the current page
- when the user pushes against the top or bottom edge twice, it turns the page

That edge behavior is driven by `_armedWheelEdge`. The first push arms the edge. The second push in the same direction triggers page navigation.

There is also a short cooldown so wheel input cannot turn multiple pages too quickly.

#### Trackpad and pan/zoom gestures

Trackpad-style events are treated differently from normal wheel events.

- `PointerPanZoomUpdateEvent` is used for trackpad-like pan input
- vertical delta is normalized by device pixel ratio
- `_trackpadPanSensitivity` reduces overly aggressive movement
- `Ctrl + pan/zoom` changes zoom instead of scrolling

In paged mode, trackpad vertical movement scrolls within the current page rather than turning pages immediately.

#### Tap and click zones

In paged mode, `_handlePagedViewportTap(...)` splits the screen into three horizontal zones:

- left third: previous page
- middle third: toggle controls
- right third: next page

If the image is zoomed in, page-turn taps are suppressed and only the middle zone toggles controls. This avoids accidental page turns while inspecting a zoomed page.

#### Double tap

Double tap resets zoom back to `1.0` on reader pages where zoom is enabled.

### Scroll controllers and viewport sync

The reader uses two levels of scrolling.

#### Screen-level scroll controller

`_scrollController` belongs to `ReaderScreen` and is only for continuous mode.

It is responsible for:

- document scrolling
- jumping to a given page when mode changes
- determining which page is currently visible

#### Per-page scroll controllers

Each `_ReaderPageState` owns `_verticalScrollController`.

This is only meaningful in paged mode and is responsible for:

- moving within a tall page
- detecting when the user has reached an edge
- resetting the scroll position when changing pages

### Page-turn logic

Paged navigation is directional rather than index-based from the user’s perspective.

`_goReadingForward(...)` and `_goReadingBackward(...)` account for `rightToLeft` by flipping whether page index increases or decreases.

When turning pages in paged mode, the reader also prepares a scroll reset anchor:

- moving forward resets the next page to the top
- moving backward resets the target page to the bottom

This matters for right-to-left reading, where “previous” and “next” are not the same as lower and higher page numbers.

### Zoom behavior

Zoom is a shared reader-level value: `_zoomLevel`.

That means:

- zoom is not stored separately for each page
- zoom changes apply to the active reader mode consistently
- when switching between continuous and paged mode, the reader resets zoom back to `1.0`

This matches the repository note that paged zoom is controlled at the reader level rather than continuously synchronized per page.

Zoom controls exist in the bottom bar and also respond to `Ctrl + wheel` or `Ctrl + trackpad pan/zoom`.

The current zoom is clamped between `0.3` and `5.0`.

### Fit modes

The reader supports four fit modes:

- `contain`
- `fitWidth`
- `fitHeight`
- `originalSize`

These are used by `_ReaderPageState._resolveImageLayout(...)` to calculate the base image size before zoom is applied.

In continuous mode the reader effectively uses `fitWidth` regardless of the saved fit mode, because the layout is a vertical scrolling document.

### Controls visibility

The reader has top and bottom chrome.

State involved:

- `_isControlsVisible`
- `_autoHideChrome`
- `_showSettingsPopover`
- `_isHoveringControls`

Behavior:

- controls start visible
- if auto-hide is enabled, a timer hides them after a short delay
- hovering the control area prevents hiding
- opening the settings popover forces controls visible
- tapping the center area or pressing `M` toggles visibility

### Cursor hiding

Desktop cursor visibility is tracked separately with:

- `_cursorVisible`
- `_cursorHideTimer`

Moving the pointer or clicking makes the cursor visible again and restarts the hide timer. After a delay, the `MouseRegion` switches to `SystemMouseCursors.none`.

### Fullscreen

Fullscreen is supported only on desktop platforms that support `window_manager` fullscreen APIs.

The reader:

- loads the stored fullscreen preference on startup
- listens for real fullscreen enter and leave events
- updates the saved preference whenever fullscreen changes

### Progress sync

Whenever the current page changes, `_setCurrentPage(...)` does three things:

1. updates the current page state
2. records a local On Deck entry
3. queues a progress sync to the server

Progress sync is debounced with `_progressSyncTimer`, so rapid scrolling or repeated page turns do not spam the API.

On success:

- `LibraryState` is updated so the library reflects the new progress
- `useLocalOnDeckFallback` is set to `false`

On failure:

- if the error message suggests server-side progress tracking is disabled, the app switches to local On Deck fallback mode
- the user sees a one-time snack bar explaining that server-side progress tracking is disabled

### End-of-archive and beginning-of-archive card

When the user tries to go past the first or last page in paged mode, the reader does not immediately leave.

Instead it uses a two-step boundary flow:

1. the first boundary attempt arms the boundary
2. a repeated attempt, or a wheel-confirmed edge action, shows `_ArchiveBoundaryCard`

The card:

- shows archive thumbnail and title
- explains that the beginning or end has been reached
- offers `Back to Library`
- offers `Dismiss`

This is the app’s “end-of-archive card.”

## 9. Widgets

### `CoverCard` in `lib/widgets/cover_card.dart`

This is the main reusable archive tile used in the library grid.

It provides:

- a 2:3 card shape
- archive thumbnail
- title overlay
- page count badge
- “Read” badge for completed archives
- click handling

Completed archives are visually dimmed by lowering thumbnail opacity.

### `ArchiveThumbnail` in `lib/widgets/cover_card.dart`

This widget builds the actual authenticated thumbnail image.

It:

- asks `Archive.thumbnailUrl(...)` for the URL
- sends auth headers from `SettingsModel`
- uses `Image.network`
- shows a plain fallback surface while loading or on error

Important detail: the stored `cropThumbnails` setting is currently not used here. The widget always defaults to `BoxFit.cover` unless another fit is passed explicitly.

### Reader private widgets

Most reader UI pieces are private widgets inside `reader_screen.dart`, including:

- `_ReaderPage`
- `_ArchiveBoundaryCard`
- `_ReaderSettingsPopover`
- `_ReaderZoomControl`
- `_ReaderBarButton`

These are only reusable inside the reader, but they matter because they divide the very large screen into manageable chunks.

### Library private widgets

`library_screen.dart` also contains many private UI helpers such as:

- `_LibrarySidebar`
- `_TopBar`
- `_ArchiveDetailsDrawer`
- `_CategoryFilterMenu`
- `_FiltersMenuButton`
- `_LibrarySearchField`
- `_LibrarySuggestionList`

They are mostly view-only wrappers around the screen’s local state and callbacks.

### Theme

`lib/widgets/theme.dart` defines `AppTheme.crimsonInk`, the app’s global theme.

Despite the name, the accent color is currently a bright cyan.

The theme sets:

- dark palette colors
- text styles using Google Fonts Inter
- input, chip, button, app bar, menu, and scrollbar theming
- consistent click cursors for interactive controls

## 10. Navigation

Navigation is simple and fully imperative.

The app does not currently use `go_router`, even though it exists in `pubspec.yaml`.

Current navigation paths are:

- app launch -> `LibraryScreen`
- library -> settings via `Navigator.push(MaterialPageRoute(...))`
- library/details or On Deck -> reader via `Navigator.push(MaterialPageRoute(...))`
- reader exit -> `Navigator.pop()` if possible

There is no deep linking, no named routes, and no dedicated navigation layer.

This keeps the app easy to reason about, but it also means navigation concerns are spread across the screens themselves.

## 11. Settings

Settings are split between connection settings, reader preferences, and local fallback data.

### Where settings are stored

In `SettingsStorageService`:

- `SharedPreferences`
  - server URL
  - thumbnail crop flag
  - reader fit mode
  - continuous scroll preference
  - right-to-left preference
  - auto-hide controls preference
  - fullscreen preference
  - local On Deck entries
  - local On Deck fallback enabled flag
- `FlutterSecureStorage`
  - API key

There is also a migration path that moves a legacy API key out of shared preferences into secure storage.

### Current settings and effects

#### Server URL

- edited in `SettingsScreen`
- determines the LANraragi base URL for all network requests

#### API key

- edited in `SettingsScreen`
- used to build bearer auth headers for every authenticated request

#### `readerFitMode`

- changed in the reader settings popover
- changes how each page is sized in paged mode

#### `readerContinuousScroll`

- changed in the reader settings popover
- switches between vertical document mode and paged mode

#### `readerRightToLeft`

- changed in the reader settings popover
- reverses page direction logic in paged mode

#### `readerAutoHideChrome`

- changed in the reader settings popover
- determines whether controls disappear after inactivity

#### `readerFullscreen`

- changed by reader fullscreen actions and window fullscreen events
- used to restore preferred fullscreen state when opening the reader on desktop

#### `onDeckEntries`

- updated while reading
- cached locally as a fallback recent-reading list

#### `useLocalOnDeckFallback`

- toggled automatically by reader progress-sync success or failure
- when true, the library sidebar stops trying to fetch On Deck from the server and uses local entries instead

#### `cropThumbnails`

- persisted in settings storage
- currently not exposed in the visible UI
- currently not applied in thumbnail rendering

So this is best thought of as dormant state, not an active feature.

## Practical Summary

If you need to change a part of the app, the fastest way to find the right file is usually:

- library browsing, filters, categories, details drawer, On Deck, random pick -> `lib/screens/library_screen.dart`
- reader controls, paging, zoom, fullscreen, progress sync -> `lib/screens/reader_screen.dart`
- LANraragi endpoints or auth behavior -> `lib/api/lanraragi_client.dart`
- archive data shape -> `lib/models/archive.dart`
- persisted settings and local fallback data -> `lib/providers/settings_provider.dart` and `lib/services/settings_storage_service.dart`
- app startup and desktop window behavior -> `lib/main.dart`

The most important architectural idea is that the app is small, direct, and screen-driven. Shared state exists, but most behavior still lives close to the screen that owns it. If you keep that in mind, the codebase is much easier to explain and modify.