# DEVONthink for Tuna

Search your DEVONthink databases, browse their contents, capture notes, and open records in DEVONthink (or with the default app) — all directly from [Tuna](https://tunaformac.com).

The extension talks to DEVONthink through its **built-in MCP stdio server** (`DEVONthink MCP.app`), not AppleScript or ScriptingBridge. That server both answers queries against your open databases and **auto-launches DEVONthink on demand**, so search, browse, and capture all just work. Results are surfaced as typed, stably identified items (UUID-based IDs); records inherit from `com.tuna.type.file`, so the built-in Open, Reveal, and Copy actions work for free alongside the custom actions. Each row shows DEVONthink's own rendered thumbnail (e.g. a PDF cover) instead of a generic file icon.

## Requirements

- macOS 15.0 or later (required by DEVONthink's MCP server)
- [Tuna](https://tunaformac.com) 0.83 or later
- TunaKit 1.17.0 or later
- [DEVONthink 4.3 "Herschel"](https://www.devontechnologies.com/apps/devonthink) or later (`com.devon-technologies.think`) — **4.3 is the first release to include the MCP server** this extension depends on

> The MCP server was introduced in DEVONthink 4.3 "Herschel". Earlier DEVONthink 4.x releases do not ship `DEVONthink MCP.app` and are not supported.

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

Builds a signed Release `.tunaextension` archive under `dist/store/`. Packaging requires a
signed Release build and a Tuna installation to read the declaration. **No paid Apple
Developer account is required** — ad-hoc signing satisfies the local codesign check, and
Tuna applies its own store signature during review/publication. To package with free
ad-hoc signing on a machine with no Apple cert configured:

```bash
TUNA_CODE_SIGN_IDENTITY=- ./scripts/tuna-extension package
```

For non-interactive builds (e.g. CI) with an Apple Development identity set up in Xcode,
pass the team and identity SHA-1 instead:

```bash
security find-identity -v -p codesigning

TUNA_DEVELOPMENT_TEAM=YOURTEAMID \
TUNA_CODE_SIGN_IDENTITY=IDENTITY_SHA1 \
  ./scripts/tuna-extension package
```

For a one-off package test, override the packaged compatibility and deployment target without editing source:

```bash
MIN_TUNA=0.83 MIN_TUNAKIT=1.17.0 MIN_MACOS=15.0 \
  ./scripts/tuna-extension package
```

## What it adds

### Catalog: DEVONthink (`devonthink.databases`)

A browsable catalog with two entries:

- **Search** — navigate in (Tab) and type a query. Results are match against **all open databases** via DEVONthink's query syntax, paginated automatically (25 per page, loading more as you scroll).
- **Browse** — navigate in to list your loaded databases, then drill into a group to reveal its contents (records and subgroups), with thumbnails.

Every result is identified by its permanent record UUID, so records are stable across rescans.

### Actions (`devonthink.actions`)

| Action | ID | Notes |
|---|---|---|
| Open in DEVONthink | `open-in-devonthink` | Opens the record in a DEVONthink window. |
| Reveal in DEVONthink | `reveal-in-devonthink` | Selects the record in DEVONthink's browser. |
| Copy Item Link | `copy-item-link` | Copies an `x-devonthink-item://` link. |
| Copy UUID | `copy-uuid` | Copies the record UUID. |
| Capture to DEVONthink | `create-note` | Creates a note from a selected text snippet. |
| Capture to DEVONthink (from app) | `create-note.from-app` | Captures text targeted at the DEVONthink app. |
| Search in DEVONthink | `search-in-devonthink` | Opens the scoped search view, prefilled with the selected text. |

Built-in file actions (Open, Reveal in Finder, Copy) apply automatically because the record type inherits from `com.tuna.type.file`.

## Privacy

This extension talks to DEVONthink **entirely through its local MCP stdio server** — a child process spawned by the extension. No network access, no telemetry, no data collection. It requests only the record metadata (uuid, name, location, kind), the file path, and the thumbnail for the results you ask for, and issues Open/Create commands when you act on a result. Nothing leaves your Mac. (DEVONthink's own MCP server can additionally redact sensitive data before sending anything to *its* AI providers — that is governed by DEVONthink's settings, not this extension.)

## Compatibility

| Floor | Version |
|---|---|
| Tuna | 0.83 |
| TunaKit | 1.17.0 |
| macOS | 15.0 |
| DEVONthink | 4.3 "Herschel" |

All catalog, action, type, and setting identifiers are stable and will not change across versions without a migration.

## Store submission

- **Bundle ID:** `com.tunaextensions.devonthink`
- **Version:** 1.0.0
- **Compatibility floors:** Tuna 0.83 · TunaKit 1.17.0 · macOS 15.0 · DEVONthink 4.3 "Herschel"
- **Privacy:** The extension talks to DEVONthink only through its local MCP stdio server. No network access, no telemetry, no data collection; nothing leaves your Mac.

Package for the store:

```bash
./scripts/tuna-extension package
```

The signed archive lands at `dist/store/com.tunaextensions.devonthink-1.0.0.tunaextension`.

## License

MIT — see [LICENSE](LICENSE).
