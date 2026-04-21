# Spike B — Spotlight + QuickLook on `.shot` UTI packages

**Issue:** `hq-alo` · **Spec ref:** SPEC.md §9 Spike B, Invariant 9

## Questions
1. Does registering `.shot` as a package UTI (conforming to `com.apple.package` +
   `public.composite-content`) let Spotlight find a capture by its OCR text?
2. Does Finder's QuickLook show `thumb.jpg` without a custom generator plugin?

Outcome does **NOT** gate Weekend 1 — SQLite+FTS5 is the load-bearing index
regardless (Invariant 9). Spike B just tells us whether Spotlight is a
nice-to-have on top, and whether a QuickLook plugin is required for v0.1.

## What this spike builds

- **`ShotfuseSpikeApp.app`** — a tiny `.app` bundle whose only purpose is to
  hold an `Info.plist` with `UTExportedTypeDeclarations` for the `.shot` UTI,
  so Launch Services has something to register.
- **`<timestamp>_….sample.shot/`** — a synthetic capture package containing:
  - `manifest.json` (spec §6.1, pinned: false)
  - `ocr.json` with a unique marker string `SHOTFUSE-SPIKE-OCR-<uuid>`
  - `master.png` (256×256 solid color)
  - `thumb.jpg` (64×64 solid color)
- **`run.sh`** — builds both, writes them to `./build-output/`, prints the
  verification commands.

## Prerequisites

- macOS 26+.
- Xcode command-line tools (`xcode-select --install`) for `swift build`.
- Admin password for `sudo mdutil` if you need a full reindex (step 6 below).

## Run

```bash
cd spikes/uti-spotlight
./run.sh
```

Then paste the printed `SHOTFUSE-SPIKE-OCR-…` marker into the `mdfind` command
that `run.sh` prints.

## Manual verification protocol

`run.sh` prints these; listed here for the record.

| # | Step | Command | Verdict signal |
|---|------|---------|----------------|
| 1 | Register bundle | `lsregister -v -f build-output/ShotfuseSpikeApp.app` (full path in run.sh output) | output mentions `dev.friquelme.shotfuse.shot` |
| 2 | UTI recognised on disk | `mdls -name kMDItemKind build-output/*.shot` | `kMDItemKind = "Shotfuse Capture Package"` (pass) vs `"Folder"` (fail) |
| 3 | Force reindex of sample | `mdimport -d1 build-output/*.shot` | debug output lists the importer picked |
| 4 | **Spotlight finds OCR text** | `mdfind "SHOTFUSE-SPIKE-OCR-<uuid>"` | returns the `.shot` path ⇒ `spotlight: yes` |
| 5 | **QuickLook preview** | `qlmanage -p build-output/*.shot` OR select in Finder + press space | preview shows thumb.jpg ⇒ `quicklook: yes`, generic folder ⇒ `quicklook: needs-plugin` |

### Why step 4 can be flaky
Spotlight's content importers are per-file-type. For `com.apple.package`
children, Spotlight descends into the package and indexes recognised file
types (JSON and PNG are recognised by default importers). If `mdfind` returns
nothing:

- Wait 10–30s (indexing is async).
- Re-run `mdimport -d1` and look for "Imported" / "Failed" lines.
- Check `mdls build-output/*.shot/ocr.json` — if `kMDItemTextContent` contains
  the marker, Spotlight HAS indexed the child; the issue is search scope.
- Last resort: `sudo mdutil -E /` rebuilds the whole volume's index (slow;
  destroys any in-progress indexing elsewhere — run overnight).

### QuickLook: expected outcome
macOS has no built-in generator for arbitrary `com.apple.package` UTIs. The
spike's hypothesis is `quicklook: needs-plugin`. A positive result
(`quicklook: yes`) would be a pleasant surprise and would mean we can skip
writing a `.qlgenerator` plugin for v0.1.

## Recording the verdict

```bash
bd update hq-alo --notes="spotlight: yes|no (mdfind returned <N> results for marker)
quicklook: yes|no|needs-plugin (qlmanage showed <description>)
kMDItemKind: <value from mdls>
Tested on: macOS <version>"

bd close hq-alo --reason="spotlight: <verdict>, quicklook: <verdict>. \
  Impact: <SQLite+FTS5 remains primary per Invariant 9 / QL plugin on roadmap>"
```

## Cleanup

```bash
# Unregister the spike bundle (optional — it's harmless if left).
"/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister" \
  -u build-output/ShotfuseSpikeApp.app

rm -rf build-output .build
```
