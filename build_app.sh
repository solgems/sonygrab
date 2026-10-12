#!/bin/bash
# Rebuild SonyGrab.app from the sources in this folder.
#
# If ./vendor exists (see fetch_vendor.sh) its Python, ffmpeg and exiftool go
# inside the bundle and the app runs on a Mac with nothing installed. Without
# it you get the small bundle that leans on whatever python3, ffmpeg, exiftool
# and Pillow the Mac already has.
#
# Building needs Apple's command line tools, for the compiler. Running the
# result does not.
set -e
cd "$(dirname "$0")"

APP="SonyGrab.app"
VERSION="${SONYGRAB_VERSION:-0}"
VENDOR_REV="${SONYGRAB_VENDOR_REV:-4}"
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

# NSAllowsLocalNetworking is for the front end showing and calling the server
# on this Mac, which is plain HTTP to 127.0.0.1.
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
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
PLIST

# The front end is what macOS runs: the Dock icon and the window the page is
# shown in. It is the only compiled part, built for both kinds of Mac so that
# an Intel one gets as far as the launcher's explanation instead of a bare
# refusal from the Finder.
if ! xcrun --find clang >/dev/null 2>&1; then
  echo "Building needs Apple's command line tools:  xcode-select --install" >&2
  exit 1
fi
xcrun clang -fobjc-arc -O2 -arch arm64 -arch x86_64 -mmacosx-version-min=11.0 \
    -framework Cocoa -framework WebKit -o "$APP/Contents/MacOS/SonyGrab" SonyGrab.m

cat > "$APP/Contents/Resources/launch.sh" <<'LAUNCH'
#!/bin/bash
# Launcher: line up the outside tools, pick the python to run on, then become
# the server. Started by the app's front end (SonyGrab.m), which shows the
# server's page in its window for as long as this runs. Everything here
# degrades rather than failing, except for having no python at all.
#
# Nothing in here may write inside the app. It is sealed when it is built, and
# macOS treats a downloaded app whose seal is broken as damaged. The log and
# any downloaded update live in the user's Library instead.
RES="$(cd "$(dirname "$0")" && pwd)"
VENDOR="$RES/vendor"
BUNDLE="$(cd "$RES/../.." && pwd)"
STATE="$HOME/Library/Application Support/SonyGrab"
LOG="$HOME/Library/Logs/SonyGrab.log"
mkdir -p "$HOME/Library/Logs"

# True when $1 is a later version than $2. Versions are dotted numbers.
version_newer() {
  case "$1" in ""|*[!0-9.]*) return 1 ;; esac
  [ "$1" != "$2" ] &&
    [ "$(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n | tail -1)" = "$1" ]
}

# Where this copy looks for updates. A build with no address never updates and
# never runs anything but the code it was built with.
UPDATE_URL=""
if [ -z "${SONYGRAB_NO_UPDATE:-}" ]; then
  UPDATE_URL="$(sed -n 's/^[[:space:]]*url[[:space:]]*=[[:space:]]*//p' "$RES/update.conf" 2>/dev/null | head -1)"
fi

# The code to run: what the app was built with, or an update downloaded since,
# whichever is newer. Installing a newer app over an older update just works.
HERE="$RES/app"
if [ -n "$UPDATE_URL" ] &&
   version_newer "$(cat "$STATE/app/VERSION" 2>/dev/null)" "$(cat "$HERE/VERSION" 2>/dev/null)"; then
  HERE="$STATE/app"
fi

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
# Pull code updates from the release server. Every failure path here is
# "carry on with what we already have" -- an update server that is merely nice
# to have is a far calmer thing to own than one the app depends on. A Mac that
# is off the network, or whose server is down, just launches.
self_update() {
  local base="$UPDATE_URL" proto tmp pid
  [ -n "$base" ] || return 0

  # Never under a copy that is already running. Its files would be swapped out
  # from under it in the middle of an import.
  pid="$(sed -n 1p "$HOME/.sonygrab.pid" 2>/dev/null)"
  case "$pid" in
    ""|*[!0-9]*) ;;
    *) kill -0 "$pid" 2>/dev/null && return 0 ;;
  esac
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

  # The front end and the bundled python/ffmpeg/exiftool are not shipped over
  # the wire, so a release that needs newer ones has to be refused rather than
  # half-applied.
  want_vendor="$(awk '$1=="vendor"{print $2; exit}' "$tmp/MANIFEST")"
  have_vendor="$(cat "$RES/vendor/REV" 2>/dev/null || echo 1)"
  if [ -n "$want_vendor" ] && [ "$want_vendor" -gt "$have_vendor" ] 2>/dev/null; then
    echo "update: $newver needs a newer app; download and install it again" >&2
    rm -rf "$tmp"; return 0
  fi

  # Fetch everything and hash-check it all before anything is put in place, so
  # a download that dies halfway leaves nothing behind.
  local kind sum name ok=1
  mkdir "$tmp/app"
  while read -r kind sum name; do
    [ "$kind" = "file" ] || continue
    if ! curl -fsSL --proto "$proto" --proto-redir "$proto" --max-time 30 \
           -o "$tmp/app/$name" "$base/$name" </dev/null; then ok=0; break; fi
    [ "$(shasum -a 256 "$tmp/app/$name" | cut -d" " -f1)" = "$sum" ] || { ok=0; break; }
  done < "$tmp/MANIFEST"
  if [ "$ok" != 1 ]; then
    echo "update: download or checksum failed, keeping $curver" >&2
    rm -rf "$tmp"; return 0
  fi
  echo "$newver" > "$tmp/app/VERSION"

  # An update is a complete copy of the code, kept outside the app, and it goes
  # in as one folder. The code is never half old and half new.
  rm -rf "$STATE/app.new" "$STATE/app.old"
  if mkdir -p "$STATE" && cp -R "$tmp/app" "$STATE/app.new" &&
     { [ ! -e "$STATE/app" ] || mv "$STATE/app" "$STATE/app.old"; } &&
     mv "$STATE/app.new" "$STATE/app"; then
    rm -rf "$STATE/app.old"
    HERE="$STATE/app"
    echo "updated $curver -> $newver"
  else
    echo "update: could not store the update, keeping $curver" >&2
  fi
  rm -rf "$tmp"
}

self_update >> "$LOG" 2>&1

cd "$HERE"

# Become the server. The front end is waiting on this process, and takes its
# end as the moment to quit. When the front end has a window ready for the
# page, the server is told not to open a browser tab as well.
exec "$PY" $PYFLAGS server.py ${SONYGRAB_WINDOW:+--no-open} >> "$LOG" 2>&1
LAUNCH

chmod +x "$APP/Contents/Resources/launch.sh"

# Clear any quarantine the vendored downloads carried in, then seal the app.
#
# A compiled front end makes macOS check a seal over everything in the bundle,
# and it treats a downloaded app whose seal does not verify as damaged, with
# no way to open it. So the seal has to be right, and has to stay right: once
# this line has run, nothing may change inside the app, here or on the Mac it
# is installed on. That is why updates and logs are kept outside it.
#
# The signature is ad hoc, not from a registered Apple developer, so the first
# launch of a downloaded copy still needs "Open Anyway".
if [ -n "$(find "$APP" -type l | head -1)" ]; then
  # Unzipping a download can leave a stray file beside a link, and one stray
  # file is enough to break the seal.
  echo "The app contains a symbolic link, which a sealed download cannot carry:" >&2
  find "$APP" -type l | sed 's/^/  /' >&2
  echo "Run ./fetch_vendor.sh --force to rebuild vendor/ without it." >&2
  exit 1
fi
xattr -cr "$APP" 2>/dev/null || true
touch "$APP"
codesign --force --sign - "$APP" 2>/dev/null
if ! codesign --verify --deep --strict "$APP"; then
  echo "The app's seal does not verify, so a downloaded copy would not open." >&2
  exit 1
fi

if [ -x "$APP/Contents/Resources/vendor/python/bin/python3" ]; then
  echo "Built $APP with its own Python and tools, $(du -sh "$APP" | cut -f1). Needs nothing installed."
elif [ "$BUNDLED" = yes ]; then
  echo "Built $APP, $(du -sh "$APP" | cut -f1). vendor/ has no python in it, so this build needs a python3 on the Mac."
  echo "Run ./fetch_vendor.sh to add one."
else
  echo "Built $APP, $(du -sh "$APP" | cut -f1). No vendor/ found, so it uses the Mac's own python3/ffmpeg/exiftool/Pillow."
  echo "Run ./fetch_vendor.sh first if you want a self-contained build."
fi
