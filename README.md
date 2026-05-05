# Kamimashita

Minimal Flutter client for LANraragi.

## Features

- Server URL + API key configuration
- Library browse and search
- Archive details and reader
- Server-backed progress when available
- On Deck and Random Pick

## Run

```bash
flutter pub get
flutter run -d windows
```

## Build

```bash
flutter build windows --release
```

## Configure

1. Launch the app.
2. Open Settings.
3. Enter the LANraragi server URL and API key.
4. Save.

## Notes

- Server-side reading progress is used when the LANraragi instance supports it.
- Random Pick and On Deck are loaded from the LANraragi API.

## Development

```bash
flutter analyze
flutter test
```
