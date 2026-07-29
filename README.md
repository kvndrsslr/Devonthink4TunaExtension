# DEVONthink for Tuna

Search all DEVONthink 4 documents and open them in DEVONthink or with the default app, directly from [Tuna](https://tunaformac.com).

This extension searches every open DEVONthink database via AppleScript, surfaces the results as typed, stably identified items (UUID-based IDs), and registers a custom type (`com.tuna.type.devonthink-record`) that inherits from `com.tuna.type.file` — so the built-in Open, Reveal, and Copy actions work for free, alongside the custom "Open in DEVONthink" action.

## Requirements

- macOS 15.0 or later
- [Tuna](https://tunaformac.com) 0.80 or later
- TunaKit 1.14.0 or later
- [DEVONthink 4](https://www.devontechnologies.com/apps/devonthink) (`com.devon-technologies.think`)

## Install

### From source (development)

Open `DevonthinkExtension.xcodeproj`, select your development team under *Signing & Capabilities*, then:

```bash
./scripts/tuna-extension install --restart
```

This builds the extension in Debug, copies it to `~/Library/Application Support/Tuna/ExtensionsDev/`, and restarts Tuna.

### Package for distribution

```bash
./scripts/tuna-extension package
```

Builds a signed Release `.tunaextension` archive under `dist/store/`. Packaging requires a signed Release build and a Tuna installation to read the declaration. For non-interactive builds (e.g. CI) without a developer team selected in Xcode:

```bash
security find-identity -v -p codesigning

TUNA_DEVELOPMENT_TEAM=YOURTEAMID \
TUNA_CODE_SIGN_IDENTITY=IDENTITY_SHA1 \
  ./scripts/tuna-extension package
```

For a one-off package test, override the packaged compatibility and deployment target without editing source:

```bash
MIN_TUNA=0.80 MIN_TUNAKIT=1.14.0 MIN_MACOS=15.0 \
  ./scripts/tuna-extension package
```

## What it adds

### Catalog: DEVONthink (`devonthink.search`)

A single search-entry item you navigate into (Tab), then type a query. DEVONthink's `search` command searches **all open databases** at once; results are paginated (configurable via the *Results per page* setting, default 7). Each result is a `DevonthinkRecordItem` identified by its permanent record UUID.

### Actions (`devonthink.actions`)

| Action | ID | Description |
|---|---|---|
| Open in DEVONthink | `open-in-devonthink` | Opens the record in a DEVONthink window. |

Built-in file actions (Open, Reveal in Finder, Copy) apply automatically because the record type inherits from `com.tuna.type.file`.

### Settings

| Setting | Key | Default |
|---|---|---|
| Results per page | `PageSize` | `7` |

## Privacy

This extension talks to DEVONthink **locally via Apple Events** (ScriptingBridge). No network access, no telemetry, no data collection. It reads record metadata (uuid, name, path, location) only for the search results you request, hands those to Tuna for display, and issues Open commands when you act on a result. Nothing leaves your Mac.

## Compatibility

| Floor | Version |
|---|---|
| Tuna | 0.80 |
| TunaKit | 1.14.0 |
| macOS | 15.0 |

All catalog, action, type, and setting identifiers are stable and will not change across versions without a migration.

## License

MIT — see [LICENSE](LICENSE).
