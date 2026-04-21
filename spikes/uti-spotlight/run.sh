#!/usr/bin/env bash
# Spike B runner — builds the tool + stub, assembles the UTI-declaring .app bundle,
# generates a sample .shot with a unique OCR marker, and prints the verification
# commands (lsregister, mdimport, mdfind, qlmanage) for the user to execute.

set -euo pipefail
cd "$(dirname "$0")"

OUTDIR="$(pwd)/build-output"
mkdir -p "$OUTDIR"

echo "==> swift build -c release"
swift build -c release

BIN_DIR="$(swift build -c release --show-bin-path)"
STUB="$BIN_DIR/ShotfuseSpikeApp"
TOOL="$BIN_DIR/SpikeTool"

echo "==> assembling .app bundle"
"$TOOL" bundle "$STUB" "$OUTDIR"

echo "==> writing sample .shot"
"$TOOL" sample "$OUTDIR"

APP="$OUTDIR/ShotfuseSpikeApp.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"

cat <<EOF

================================================================================
Next — manual verification steps (run in your shell):

  # 1. Register the UTI-declaring app with Launch Services.
  "$LSREGISTER" -v -f "$APP"

  # 2. Confirm UTI is known.
  mdls -name kMDItemKind "$OUTDIR"/*.shot | head -1

  # 3. Force Spotlight to index the sample package.
  mdimport -d1 "$OUTDIR"/*.shot

  # 4. Search Spotlight for the unique OCR marker printed above.
  mdfind "SHOTFUSE-SPIKE-OCR-<paste-uuid>"
  #   expected PASS:  returns the .shot package path
  #   expected FAIL:  returns nothing even after 10s

  # 5. QuickLook preview (press space in Finder, or CLI):
  qlmanage -p "$OUTDIR"/*.shot
  #   expected PASS:  preview window shows thumb.jpg
  #   expected FAIL:  generic folder icon / "No preview available"

  # 6. Optional nuclear option (rebuilds Spotlight index on the whole volume):
  #   sudo mdutil -E /
  # Only use if step 4 is ambiguous — see README.
================================================================================
EOF
