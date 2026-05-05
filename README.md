# pleasure_principle

Minimal Flutter client for LANraragi.

## Requirements

- A running LANraragi instance
- A valid LANraragi API key
- Flutter 3 with Dart 3.11+

## Screenshots

Screenshots are not committed in this repository yet.

## What It Does

- Configure a LANraragi server URL and API key
- Browse and search the library with filters and sorting
- Open archive details, covers, and source links
- Read archives with synced reading progress
- Surface Random Pick and On Deck from the server

## Run It

```bash
flutter pub get
flutter run -d windows
```

You can also run on another supported Flutter target if needed.

## Build

```bash
flutter build windows
```

## Configure It

1. Launch the app.
2. Open Settings.
3. Enter your LANraragi server URL and API key.
4. Save and refresh the library.

## LANraragi Notes

- Server-side reading progress is used when the LANraragi instance supports it.
- Random Pick and On Deck are loaded from the LANraragi API.

## Development

```bash
flutter analyze
flutter test
```
