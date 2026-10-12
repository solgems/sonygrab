#!/bin/bash
# Rebuild SonyGrab.app from the sources in this folder.
#
# If ./vendor exists (see fetch_vendor.sh) its Python, ffmpeg and exiftool go
# inside the bundle and the app runs on a Mac with nothing installed. Without
# it you get the small bundle that leans on whatever python3, ffmpeg, exiftool
# and Pillow the Mac already has.
set -e
cd "$(dirname "$0")"

APP="SonyGrab.app"
VERSION="${SONYGRAB_VERSION:-0}"
VENDOR_REV="${SONYGRAB_VENDOR_REV:-2}"
UPDATE_URL="${SONYGRAB_UPDATE_URL:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --out) shift; APP="$1" ;;
    --update-url) shift; UPDATE_URL="$1" ;;
    --version) shift; VERSION="$1" ;;
    -h|--help)
      echo "usage: ./build_app.sh [--out NAME.app] [--update-url URL] [--version V]"
      echo
      echo "  --out          write to NAME.app instead of SonyGrab.app"
      echo "  --update-url   where the built app looks for updates"
      echo "  --version      the version this build reports to the updater"
      exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/app"

cp core.py photo.py compress.py pipeline.py server.py ui.html "$APP/Contents/Resources/app/"
[ -f SonyGrab.icns ] && cp SonyGrab.icns "$APP/Contents/Resources/"

if [ -d vendor ]; then
  cp -R vendor "$APP/Contents/Resources/vendor"
  # The bundled tools come with licences that have to travel with them.
  cp THIRD_PARTY.md "$APP/Contents/Resources/"
  cp -R licenses "$APP/Contents/Resources/licenses"
  BUNDLED="yes"
else
  BUNDLED="no"
fi

echo "$VERSION" > "$APP/Contents/Resources/app/VERSION"
echo "$VENDOR_REV" > "$APP/Contents/Resources/vendor/REV" 2>/dev/null || true

# Where this copy looks for updates. It sits in Resources rather than
# Resources/app, because everything in app/ is replaced by an update and this
# must not be.
cat > "$APP/Contents/Resources/update.conf" <<CONF
# Where this Mac looks for updates. Blank or missing disables them.
url = $UPDATE_URL
CONF

# LSArchitecturePriority matters more than it looks. The executable is a shell
# script, so macOS has no binary to read an architecture from, assumes Intel
# and starts the launcher under Rosetta -- and on an Apple silicon Mac that
# has never installed Rosetta, it asks to install it before the app will open.
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>SonyGrab</string>
  <key>CFBundleDisplayName</key><string>SonyGrab</string>
  <key>CFBundleIdentifier</key><string>local.sonygrab</string>
  <key>CFBundleVersion</key><string>1.1</string>
  <key>CFBundleShortVersionString</key><string>1.1</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>SonyGrab</string>
  <key>CFBundleIconFile</key><string>SonyGrab</string>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
  <key>LSArchitecturePriority</key><array><string>arm64</string><string>x86_64</string></array>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

cat > "$APP/Contents/MacOS/SonyGrab" <<'LAUNCH'
#!/bin/bash
# Launcher: line up the outside tools, pick the python to run on, hand off to
# the server. Everything here degrades rather than failing, except for having
# no python at all.
RES="$(cd "$(dirname "$0")/.." && pwd)/Resources"
HERE="$RES/app"
VENDOR="$RES/vendor"
BUNDLE="$(cd "$(dirname "$0")/../.." && pwd)"
LOG="$HOME/Library/Logs/SonyGrab.log"
mkdir -p "$HOME/Library/Logs"

# One line per launch. When this is running on someone else's Mac, the log is
# the only way to see what happened there.
echo "launcher: $(date '+%Y-%m-%d %H:%M:%S') version $(cat "$HERE/VERSION" 2>/dev/null || echo '?') on $(uname -m), macOS $(sw_vers -productVersion 2>/dev/null), from $BUNDLE" >> "$LOG"

# A bundle that arrived by AirDrop, download or email is quarantined, and macOS
# will then refuse to exec the python, ffmpeg and exiftool we ship inside it.
# By the time this script runs the user has already cleared the app itself, so
# clear the payload to match. Runs once. Failing here is not fatal by itself;
# if python then cannot start, the alert further down says what to do.
BUNDLED_PY="$VENDOR/python/bin/python3"
if xattr -p com.apple.quarantine "$BUNDLE" >/dev/null 2>&1 ||
   xattr -p com.apple.quarantine "$VENDOR/bin/ffmpeg" >/dev/null 2>&1 ||
   xattr -p com.apple.quarantine "$BUNDLED_PY" >/dev/null 2>&1; then
  xattr -dr com.apple.quarantine "$BUNDLE" 2>/dev/null || true
  # xattr reports success whether or not it managed to, so look again.
  if xattr -p com.apple.quarantine "$BUNDLED_PY" >/dev/null 2>&1 ||
     xattr -p com.apple.quarantine "$VENDOR/bin/ffmpeg" >/dev/null 2>&1; then
    echo "launcher: could not clear the quarantine flag inside the bundle" >> "$LOG"
  fi
fi

# Tools we ship come first, then Homebrew, which lives outside the GUI PATH.
# core.py/compress.py locate ffmpeg, ffprobe and exiftool with shutil.which,
# so PATH is the whole mechanism -- no code in the app knows about vendoring.
if [ -d "$VENDOR/bin" ]; then
  export PATH="$VENDOR/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
else
  export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
fi

# The python we ship comes first. Pillow is installed into it, so there is
# nothing to match up and every Mac runs the same interpreter. -E and -s keep
# a stray PYTHONPATH or a user-level site-packages from reaching it, and -B
# keeps the bundle immutable: no .pyc written back into it.
PY=""; PYFLAGS="-B"; BUNDLED_FAILED=""
if [ -x "$BUNDLED_PY" ]; then
  if "$BUNDLED_PY" -B -E -s -c 'import json,http.server' >/dev/null 2>>"$LOG"; then
    PY="$BUNDLED_PY"; PYFLAGS="-B -E -s"
  else
    echo "launcher: the bundled python would not start (exit $?)" >> "$LOG"
    BUNDLED_FAILED=1
  fi
fi

# No python of our own (a build made without vendor/), or it would not run:
# look for one already on the Mac. Two passes over the same candidates: first
# insisting on a working Pillow, then settling for any python at all, so a Mac
# without Pillow still imports photos.
#
# /usr/bin/python3 is a stub until Apple's developer tools are installed, and
# running the stub puts up an "install the developer tools?" dialog. So it is
# only a candidate when the real interpreter is sitting behind it.
if [ -z "$PY" ]; then
  CANDIDATES="/opt/homebrew/bin/python3 /usr/local/bin/python3"
  if [ -x "$(/usr/bin/xcode-select -p 2>/dev/null)/usr/bin/python3" ]; then
    CANDIDATES="$CANDIDATES /usr/bin/python3"
  fi
  for want_pil in yes no; do
    for c in $CANDIDATES; do
      [ -x "$c" ] || continue
      "$c" -c 'import json,http.server' >/dev/null 2>&1 || continue
      if [ "$want_pil" = yes ]; then
        "$c" -c 'from PIL import Image' >/dev/null 2>&1 || continue
      fi
      PY="$c"; break
    done
    [ -n "$PY" ] && break
  done
  [ -n "$PY" ] && echo "launcher: falling back to $PY" >> "$LOG"
fi

if [ -z "$PY" ]; then
  if [ -z "$BUNDLED_FAILED" ]; then
    MSG="Python 3 could not be found on this Mac.

Open Terminal and run:    xcode-select --install

That installs Apple's own Python, which is all SonyGrab needs. Then try again."
  elif [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" != 1 ]; then
    MSG="This copy of SonyGrab is built for Macs with Apple silicon, and this Mac has an Intel processor."
  else
    # A downloaded app that has not been moved yet is run by macOS from a
    # read-only temporary copy, where the quarantine flag cannot be cleared.
    # Moving it with Finder ends that, and is harmless advice otherwise.
    MSG="SonyGrab could not start.

Drag SonyGrab into your Applications folder, then open it from there.

If it is already there, this copy is incomplete or still blocked by macOS. Download it again."
  fi
  echo "launcher: no usable python, giving up" >> "$LOG"
  osascript -e 'on run argv' \
            -e 'display alert "SonyGrab" message (item 1 of argv) as critical' \
            -e 'end run' "$MSG"
  exit 1
fi

# ------------------------------------------------------------------ updates
# True when $1 is a later version than $2. Versions are dotted numbers.
version_newer() {
  case "$1" in ""|*[!0-9.]*) return 1 ;; esac
  [ "$1" != "$2" ] &&
    [ "$(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n | tail -1)" = "$1" ]
}

# Pull code updates from the release server. Every failure path here is
# "carry on with what we already have" -- an update server that is merely nice
# to have is a far calmer thing to own than one the app depends on. A Mac that
# is off the network, or whose server is down, just launches.
self_update() {
  local cfg="$RES/update.conf" base proto tmp pid
  [ -z "${SONYGRAB_NO_UPDATE:-}" ] || return 0
  [ -f "$cfg" ] || return 0

  # Never under a copy that is already running. A second double-click in the
  # middle of an import would otherwise swap its files out from under it.
  pid="$(sed -n 1p "$HOME/.sonygrab.pid" 2>/dev/null)"
  case "$pid" in
    ""|*[!0-9]*) ;;
    *) kill -0 "$pid" 2>/dev/null && return 0 ;;
  esac
  base="$(sed -n 's/^[[:space:]]*url[[:space:]]*=[[:space:]]*//p' "$cfg" | head -1)"
  [ -n "$base" ] || return 0
  command -v curl >/dev/null 2>&1 || return 0

  # The HTTPS connection is what guarantees these files are the ones in the
  # release, so nothing else is accepted, redirects included. Plain HTTP is
  # allowed only to this Mac itself, for testing.
  case "$base" in
    https://*) proto="=https" ;;
    http://127.0.0.1:*) proto="=http" ;;
    *) return 0 ;;
  esac

  tmp="$(mktemp -d)" || return 0

  # Stderr is discarded on purpose: an unreachable server is the normal case
  # for a laptop away from home, not something to log on every launch.
  # -L because a GitHub release link answers with a redirect to the file.
  if ! curl -fsSL --proto "$proto" --proto-redir "$proto" --max-time 6 \
         -o "$tmp/MANIFEST" "$base/MANIFEST" </dev/null 2>/dev/null; then
    rm -rf "$tmp"; return 0
  fi

  local newver curver want_vendor have_vendor
  newver="$(awk '$1=="version"{print $2; exit}' "$tmp/MANIFEST")"
  curver="$(cat "$HERE/VERSION" 2>/dev/null || echo 0)"
  # Only ever forwards. Otherwise a copy built today would be "updated" back to
  # whatever older release is still being served.
  version_newer "$newver" "$curver" || { rm -rf "$tmp"; return 0; }

  # The bundled ffmpeg/exiftool are not shipped over the wire, so a release
  # that needs newer ones has to be refused rather than half-applied.
  want_vendor="$(awk '$1=="vendor"{print $2; exit}' "$tmp/MANIFEST")"
  have_vendor="$(cat "$RES/vendor/REV" 2>/dev/null || echo 1)"
  if [ -n "$want_vendor" ] && [ "$want_vendor" -gt "$have_vendor" ] 2>/dev/null; then
    echo "update: $newver needs a newer tool bundle; install a fresh copy" >&2
    rm -rf "$tmp"; return 0
  fi

  # Fetch everything and hash-check it all before the bundle is touched, so a
  # download that dies halfway cannot leave a half-updated app behind.
  local kind sum name ok=1
  while read -r kind sum name; do
    [ "$kind" = "file" ] || continue
    if ! curl -fsSL --proto "$proto" --proto-redir "$proto" --max-time 30 \
           -o "$tmp/$name" "$base/$name" </dev/null; then ok=0; break; fi
    [ "$(shasum -a 256 "$tmp/$name" | cut -d" " -f1)" = "$sum" ] || { ok=0; break; }
  done < "$tmp/MANIFEST"
  if [ "$ok" != 1 ]; then
    echo "update: download or checksum failed, keeping $curver" >&2
    rm -rf "$tmp"; return 0
  fi

  while read -r kind sum name; do
    [ "$kind" = "file" ] || continue
    cp "$tmp/$name" "$HERE/$name" || { echo "update: bundle not writable" >&2; rm -rf "$tmp"; return 0; }
  done < "$tmp/MANIFEST"
  echo "$newver" > "$HERE/VERSION" 2>/dev/null || true
  echo "updated $curver -> $newver"
  rm -rf "$tmp"
}

self_update >> "$LOG" 2>&1

cd "$HERE"

# Start detached and exit straight away. macOS then never considers the app
# "running", so every double-click re-runs this -- and server.py notices an
# existing instance and just reopens the browser instead of starting a second.
nohup "$PY" $PYFLAGS server.py >> "$LOG" 2>&1 &
disown 2>/dev/null || true
exit 0
LAUNCH

chmod +x "$APP/Contents/MacOS/SonyGrab"

# Clear any quarantine the vendored downloads carried in, so the copy built
# here is launchable immediately.
#
# Deliberately NOT codesigning the bundle. An ad-hoc signature buys nothing
# against Gatekeeper, and it seals a directory that cannot stay sealed -- the
# app writes logs and Python may drop .pyc files inside it. macOS treats a
# quarantined bundle whose signature fails to verify as damaged and will delete
# it outright. No signature is strictly safer than a broken one. The Mach-O
# binaries inside keep their own valid signatures, which is what arm64 needs.
xattr -cr "$APP" 2>/dev/null || true

touch "$APP"
if [ -x "$APP/Contents/Resources/vendor/python/bin/python3" ]; then
  echo "Built $APP with its own Python and tools, $(du -sh "$APP" | cut -f1). Needs nothing installed."
elif [ "$BUNDLED" = yes ]; then
  echo "Built $APP, $(du -sh "$APP" | cut -f1). vendor/ has no python in it, so this build needs a python3 on the Mac."
  echo "Run ./fetch_vendor.sh to add one."
else
  echo "Built $APP, $(du -sh "$APP" | cut -f1). No vendor/ found, so it uses the Mac's own python3/ffmpeg/exiftool/Pillow."
  echo "Run ./fetch_vendor.sh first if you want a self-contained build."
fi
