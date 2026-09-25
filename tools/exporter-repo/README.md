# Lightbrary Exporter

A small menu-bar app for the Mac that holds your Photos library. It reads what
Photos has already worked out about your pictures — sharpness, exposure, faces,
some forty other measures, places, scenes, people and pets, text in the photo,
camera settings — and writes it to a folder you choose, normally in iCloud
Drive. [Lightbrary](https://lightbrary.app) on the iPhone and the Mac reads that
file to filter, sort and search your library by it.

Photos keeps all of this in databases inside the library package, and PhotoKit
— Apple's public API — does not expose it. The exporter is the one piece that
reads those databases, and it is open so you can see exactly what it does.

**Download** a signed and notarised build from
[lightbrary.app/download](https://lightbrary.app/download#exporter) or the
[releases](https://github.com/RadioErewan/lightbrary-exporter/releases).
macOS 27 or later, Apple silicon.

## What it touches

- **Reads, never writes, your library.** The databases are opened read-only
  (`SQLITE_OPEN_READONLY` with `mode=ro`, falling back to `immutable=1`);
  photos are listed through PhotoKit only to match identifiers. Nothing in the library is ever changed.
- **Writes one file** — `ibrowse-<device>-features.ibsync` — into the folder
  you pick, and nothing anywhere else.
- **Sends nothing anywhere.** There is no network code; the file travels only
  if the folder you picked is synced, e.g. by iCloud Drive.
- **Leaves out names read from identity documents** (the `11010` category of
  the Photos search index). Everything else in the file is what Photos
  already shows you about your own photos.
- **Permissions:** photo library access. On macOS 27 that is enough; Full Disk
  Access is only a fallback if it reports that it cannot read the library.

It exports on its own a few minutes after your library stops changing, and
**Export now** in the menu does it straight away.

## The file

A SQLite file, format version 6 (`meta.schema`). Readers look columns up by
name, so new columns never break older readers; `meta.minReader` says which
reader version is required.

Table `feature`, one row per photo:

| column | meaning |
|---|---|
| `assetID` | iCloud identifier of the photo (`PHCloudIdentifier`), the same on every device |
| `sharpness`, `exposure` | 0–1, from the Photos analysis; 0 means not measured |
| `faces`, `eyesClosed`, `smiles`, `screenshot` | counts and flag |
| `measures` | packed: for each of ~40 measures, 1 byte code + 4 byte float32, little-endian |
| `terms` | search words, one per line (base forms, not synonyms) |
| `panel` | JSON: `place`, `people`, `pets`, `scenes`, `occasion`, `words`, `camera`, `lens`, `iso`, `aperture`, `shutter`, `focal`, `flash` |

The layout of the Photos databases is undocumented and changes between macOS
versions (macOS 27 replaced `psi.sqlite` with `leo.sqlite`). If a macOS update
breaks the exporter, that is why — please open an issue.

## Building

```
brew install xcodegen
cp Local.xcconfig.example Local.xcconfig   # your Apple Developer team ID
xcodegen generate
open lightbrary-exporter.xcodeproj
```

This repository is published from the main Lightbrary repository
([RadioErewan/ibrowse](https://github.com/RadioErewan/ibrowse)), where the
exporter and the apps share the file format. Code comments are in Polish.

## License

MIT — see [LICENSE](LICENSE).
