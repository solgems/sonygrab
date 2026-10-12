#!/bin/bash
# Populate ./vendor with everything SonyGrab runs on, so the built app needs
# nothing installed on the Mac it lands on -- not even Apple's developer tools.
#
#   python             standalone CPython, with Pillow installed into it
#   ffmpeg + ffprobe   static arm64 builds, no Homebrew dylibs
#   exiftool           pure Perl, runs on the /usr/bin/perl macOS ships
#
# Run this once, then ./build_app.sh. Whatever is already in vendor/ is kept,
# so a second run only fetches what is missing. --force starts from nothing,
# which is how you pick up new versions.
# Needs a network connection; the app itself never does.
set -euo pipefail
cd "$(dirname "$0")"

FORCE=""
case "${1:-}" in
  --force) FORCE=1 ;;
  "") ;;
  *) echo "usage: ./fetch_vendor.sh [--force]" >&2; exit 2 ;;
esac

FFMPEG_URL="https://www.osxexperts.net/ffmpeg9arm.zip"
FFPROBE_URL="https://www.osxexperts.net/ffprobe9arm.zip"
EXIFTOOL_VER="13.59"
EXIFTOOL_URL="https://sourceforge.net/projects/exiftool/files/Image-ExifTool-${EXIFTOOL_VER}.tar.gz/download"

# Both of these are pinned by hash. To move to a newer one, change the version
# and take the new hash from the project's own published list:
#   python   SHA256SUMS on the python-build-standalone release page
#   Pillow   the cp312 macosx_11_0_arm64 wheel under "Download files" on PyPI
PYTHON_VER="3.12.15"
PYTHON_BUILD="20261009"
PYTHON_SHA256="233f8e15255b3e1d1fd47ea5dd5230dfed803f371138e896e54d98c60ae19f6f"
PYTHON_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PYTHON_BUILD}/cpython-${PYTHON_VER}%2B${PYTHON_BUILD}-aarch64-apple-darwin-install_only_stripped.tar.gz"
PILLOW_VER="12.3.0"
PILLOW_SHA256="ffd0c5368496f41b0944be820fcb7a838aa6e623d250b01acf2643939c3f99d7"

VENDOR="$PWD/vendor"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [ "$(uname -m)" != "arm64" ]; then
  echo "This fetches Apple Silicon binaries and you are on $(uname -m)." >&2
  echo "Swap the ffmpeg/ffprobe URLs for the intel builds on osxexperts.net," >&2
  echo "and the python URL for the x86_64-apple-darwin build." >&2
  exit 1
fi

say() { printf '  %s\n' "$*"; }

check_sha256() {
  local got
  got="$(shasum -a 256 "$1" | cut -d" " -f1)"
  if [ "$got" != "$2" ]; then
    echo "Checksum mismatch for $(basename "$1"), not using it." >&2
    echo "  expected $2" >&2
    echo "  got      $got" >&2
    exit 1
  fi
}

echo "Fetching into vendor/"
[ -n "$FORCE" ] && rm -rf "$VENDOR"
mkdir -p "$VENDOR/bin" "$VENDOR/exiftool"

# ---------------------------------------------------------------- ffmpeg
if [ -x "$VENDOR/bin/ffmpeg" ] && [ -x "$VENDOR/bin/ffprobe" ]; then
  say "ffmpeg + ffprobe: already here, keeping them"
else
  say "ffmpeg + ffprobe (about 45 MB, two downloads)"
  curl -fsSL -o "$TMP/ffmpeg.zip"  "$FFMPEG_URL"
  curl -fsSL -o "$TMP/ffprobe.zip" "$FFPROBE_URL"
  unzip -oq "$TMP/ffmpeg.zip"  -d "$TMP/ff"
  unzip -oq "$TMP/ffprobe.zip" -d "$TMP/ff"
  mv "$TMP/ff/ffmpeg" "$TMP/ff/ffprobe" "$VENDOR/bin/"
  chmod +x "$VENDOR/bin/ffmpeg" "$VENDOR/bin/ffprobe"

  # These are Mach-O binaries pulled off the net, so they arrive quarantined and
  # arm64 refuses to exec anything whose signature does not check out.
  xattr -cr "$VENDOR/bin/ffmpeg" "$VENDOR/bin/ffprobe" 2>/dev/null || true
  for b in ffmpeg ffprobe; do
    codesign -dv "$VENDOR/bin/$b" >/dev/null 2>&1 || codesign -fs - "$VENDOR/bin/$b" >/dev/null 2>&1 || true
  done
fi

# ---------------------------------------------------------------- exiftool
if [ -f "$VENDOR/exiftool/exiftool" ] && [ -x "$VENDOR/bin/exiftool" ]; then
  say "exiftool: already here, keeping it"
else
  say "exiftool $EXIFTOOL_VER (pure Perl, about 8 MB)"
  curl -fsSL -o "$TMP/exiftool.tar.gz" "$EXIFTOOL_URL"
  tar xzf "$TMP/exiftool.tar.gz" -C "$TMP"
  SRC="$TMP/Image-ExifTool-$EXIFTOOL_VER"
  cp "$SRC/exiftool" "$VENDOR/exiftool/"
  cp -R "$SRC/lib" "$VENDOR/exiftool/"
  chmod +x "$VENDOR/exiftool/exiftool"

  # core.py finds exiftool with shutil.which, so it has to be on PATH as a plain
  # name. The wrapper also pins the system perl rather than whatever is first.
  cat > "$VENDOR/bin/exiftool" <<'WRAP'
#!/bin/bash
D="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec /usr/bin/perl "$D/exiftool/exiftool" "$@"
WRAP
  chmod +x "$VENDOR/bin/exiftool"
fi

# ---------------------------------------------------------------- python
# /usr/bin/python3 on a stock Mac is a stub. It only becomes an interpreter once
# the Command Line Tools are installed, so the app cannot count on it. This is
# a relocatable CPython from the python-build-standalone project: unpack it
# anywhere and it runs. -E and -s keep this Mac's own Python settings and
# packages out of it, here and in the launcher.
P="$VENDOR/python"
PY="$P/bin/python3"
if [ -x "$PY" ] && "$PY" -B -E -s -c 'from PIL import Image' >/dev/null 2>&1; then
  say "python: already here ($("$PY" -V 2>&1 | cut -d" " -f2)), keeping it"
else
  say "python $PYTHON_VER (about 25 MB)"
  rm -rf "$P"
  curl -fsSL -o "$TMP/python.tar.gz" "$PYTHON_URL"
  check_sha256 "$TMP/python.tar.gz" "$PYTHON_SHA256"
  tar xzf "$TMP/python.tar.gz" -C "$VENDOR"     # the archive's top level is python/

  say "Pillow $PILLOW_VER, installed into that python"
  printf 'pillow==%s --hash=sha256:%s\n' "$PILLOW_VER" "$PILLOW_SHA256" > "$TMP/requirements.txt"
  "$PY" -B -E -s -m pip install --isolated --no-cache-dir --require-hashes \
      --only-binary=:all: --no-deps --no-compile --quiet \
      --disable-pip-version-check -r "$TMP/requirements.txt"

  # Drop what a headless importer never loads: Tcl/Tk and the GUI modules built
  # on it, the packaging tools (Pillow is in and nothing else gets installed),
  # the C headers, and a second copy of the interpreter as a shared library
  # that the python3 binary does not link against. Roughly halves it.
  L="$P/lib/python${PYTHON_VER%.*}"
  rm -rf "$P/include" "$P/share" "$P/lib/pkgconfig" \
         "$P"/lib/libpython*.dylib \
         "$P"/lib/libtcl* "$P"/lib/tcl* "$P"/lib/tk* "$P"/lib/itcl* "$P"/lib/thread* \
         "$L/tkinter" "$L/idlelib" "$L/turtledemo" "$L/turtle.py" \
         "$L"/lib-dynload/_tkinter* \
         "$L/ensurepip" "$L/lib2to3" \
         "$L/site-packages/pip" "$L"/site-packages/pip-*.dist-info
  find "$P/bin" -mindepth 1 ! -name python3 ! -name "python${PYTHON_VER%.*}" -delete
  xattr -cr "$P" 2>/dev/null || true

  # Prove the trimmed interpreter still loads everything the app imports, and
  # that Pillow can do the one thing it is here for.
  "$PY" -B -E -s -c '
import fcntl, hashlib, http.server, io, json, math, re, secrets, shutil, socket
import subprocess, sys, threading, webbrowser, dataclasses, datetime, pathlib, urllib.parse
from PIL import Image, ImageOps, features
assert features.check("jpg"), "this Pillow cannot read or write JPEG"
print("  verified: Python %d.%d.%d, Pillow %s" % (sys.version_info[:3] + (Image.__version__,)))
'
fi

echo
echo "vendor/ is $(du -sh "$VENDOR" | cut -f1). Now run ./build_app.sh"
