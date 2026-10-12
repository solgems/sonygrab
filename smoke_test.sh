#!/bin/bash
# End-to-end check of a built SonyGrab.app. Starts it the way Finder would, on
# a pretend Mac that has no developer tools and no Homebrew, imports a pretend
# card through the real HTTP API, and checks what landed on disk.
#
#   ./smoke_test.sh [path/to/SonyGrab.app] [--quarantined]
#
# --quarantined first copies the app and flags every file in the copy the way
# a Safari download would be, to exercise the launcher's self-clearing.
#
# It is safe to run while you are importing for real. The test instance gets
# its own HOME, so it has its own lock, pidfile, log and Pictures folder, and
# it opens no browser window. It only ever stops the server it started.
set -uo pipefail
cd "$(dirname "$0")"

APP_ARG="SonyGrab.app"; QUARANTINED=""
for a in "$@"; do
  case "$a" in
    --quarantined) QUARANTINED=1 ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) APP_ARG="$a" ;;
  esac
done
[ -d "$APP_ARG/Contents/MacOS" ] || { echo "no app at $APP_ARG (run ./build_app.sh first)" >&2; exit 2; }
APP="$(cd "$APP_ARG" && pwd)"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/sonygrab-test.XXXXXX")"
FAKE_HOME="$WORK/home"; CARD="$WORK/card"; OUT="$WORK/out"
mkdir -p "$FAKE_HOME" "$WORK/tmp" "$CARD/DCIM/100MSDCF" "$CARD/PRIVATE/M4ROOT/CLIP"
PID=""

cleanup() {
  # Only ever the server this run started, identified by its own pidfile.
  if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then kill "$PID" 2>/dev/null; fi
  rm -rf "$WORK"
}
trap cleanup EXIT

FAILS=0
ok()   { printf '  ok    %s\n' "$*"; }
bad()  { printf '  FAIL  %s\n' "$*"; FAILS=$((FAILS + 1)); }
check() { local what="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$what"; else bad "$what"; fi; }

if [ -n "$QUARANTINED" ]; then
  mkdir -p "$WORK/Downloads"
  cp -R "$APP" "$WORK/Downloads/"
  APP="$WORK/Downloads/$(basename "$APP")"
  xattr -rw com.apple.quarantine "0083;670a0000;Safari;" "$APP"
  echo "Testing a quarantined copy: $(xattr -r "$APP" 2>/dev/null | grep -c quarantine) files flagged"
fi

RES="$APP/Contents/Resources"
PY="$RES/vendor/python/bin/python3"
TOOLS="$RES/vendor/bin"
py() { "$PY" -B -E -s "$@"; }

echo "App under test: $APP"
[ -x "$PY" ] || { echo "this build has no bundled python, nothing to test" >&2; exit 2; }

# ------------------------------------------------------------------ fixtures
# Built before the app starts, and in a private copy of the tools so that the
# quarantined run still gets to see a fully flagged bundle on first launch.
echo "Building a pretend card"
FIX="$WORK/fixtools"; cp -R "$RES/vendor" "$FIX"; xattr -cr "$FIX" 2>/dev/null
FPY="$FIX/python/bin/python3"
J="$CARD/DCIM/100MSDCF"
"$FPY" -B -E -s - "$J/DSC00001.JPG" "$J/DSC00002.JPG" <<'PYEOF'
import sys
from PIL import Image
g = Image.linear_gradient("L").resize((6000, 4000))
im = Image.merge("RGB", (g, g.rotate(180), g.transpose(Image.FLIP_LEFT_RIGHT)))
for out in sys.argv[1:]:
    im.save(out, quality=92)
PYEOF
ET="/usr/bin/perl $FIX/exiftool/exiftool -q -overwrite_original"
$ET -Model=ILCE-7M4 -DateTimeOriginal="2026:10:04 10:11:12" -CreateDate="2026:10:04 10:11:12" \
    -GPSLatitude=1.3521 -GPSLatitudeRef=N -GPSLongitude=103.8198 -GPSLongitudeRef=E "$J/DSC00001.JPG"
$ET -Model=ILCE-7M4 -DateTimeOriginal="2026:10:05 09:00:00" -CreateDate="2026:10:05 09:00:00" "$J/DSC00002.JPG"
head -c 300000 /dev/urandom > "$J/DSC00001.ARW"; touch -t 202610041011.12 "$J/DSC00001.ARW"
HAVE_HIF=""
if sips -s format heic "$J/DSC00001.JPG" --out "$WORK/tmp/x.heic" >/dev/null 2>&1; then
  mv "$WORK/tmp/x.heic" "$J/DSC00003.HIF"
  $ET -DateTimeOriginal="2026:10:04 10:20:00" "$J/DSC00003.HIF" && HAVE_HIF=1
fi
# +faststart puts the clip's index ahead of its picture data. The app reads
# dates with "exiftool -fast2", which stops at the picture data, so a clip laid
# out the other way round reads as undated and is filed by its file timestamp.
V="$CARD/PRIVATE/M4ROOT/CLIP/C0001.MP4"
"$FIX/bin/ffmpeg" -v error -f lavfi -i testsrc2=size=3840x2160:rate=25 -f lavfi -i sine=frequency=440 \
    -t 2 -c:v h264_videotoolbox -b:v 20M -pix_fmt yuv420p -c:a aac -movflags +faststart \
    -metadata creation_time=2026-10-04T08:00:00Z "$V" || bad "could not make the test clip"
rm -rf "$FIX"

# -------------------------------------------------------------------- launch
# env -i gives the launcher the bare environment a Finder launch has. The
# sandbox makes the developer tools and Homebrew unreadable, and refuses to
# run Apple's python3 stub at all -- on a Mac without the tools, running it
# only puts up an "install the developer tools?" dialog. Updates are switched
# off so that the test runs the code in this build and nothing newer.
SANDBOX='(version 1)(allow default)
(deny file-read* (subpath "/Library/Developer") (subpath "/Applications/Xcode.app")
                 (subpath "/opt/homebrew") (subpath "/usr/local"))
(deny process-exec (literal "/usr/bin/python3") (literal "/usr/bin/xcrun"))'
echo "Launching with developer tools and Homebrew blocked"
env -i HOME="$FAKE_HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin TMPDIR="$WORK/tmp" BROWSER=/usr/bin/true \
  SONYGRAB_NO_UPDATE=1 \
  /usr/bin/sandbox-exec -p "$SANDBOX" /bin/bash "$APP/Contents/MacOS/SonyGrab"
LOG="$FAKE_HOME/Library/Logs/SonyGrab.log"

URL=""
for _ in $(seq 1 100); do
  if [ -s "$FAKE_HOME/.sonygrab.pid" ]; then
    PID="$(sed -n 1p "$FAKE_HOME/.sonygrab.pid")"; URL="$(sed -n 2p "$FAKE_HOME/.sonygrab.pid")"
    [ -n "$URL" ] && break
  fi
  perl -e 'select(undef,undef,undef,0.1)'
done
if [ -z "$URL" ]; then
  bad "the server never came up"; echo "--- log"; cat "$LOG" 2>/dev/null; exit 1
fi
BASE="${URL%%/\?*}"; TOKEN="${URL##*t=}"
ok "server is up ($BASE, pid $PID)"

get()  { curl -fsS --max-time 20 -H "X-Token: $TOKEN" "$BASE$1"; }
post() { curl -fsS --max-time 60 -H "X-Token: $TOKEN" -H "Content-Type: application/json" -d "$2" "$BASE$1"; }
field() { py -c 'import json,sys; d=json.load(sys.stdin)
for k in sys.argv[1].split("."): d=d[k]
print(d)' "$1"; }

case "$(ps -o command= -p "$PID")" in
  "$PY "*) ok "running on the bundled python" ;;
  *) bad "not running on the bundled python: $(ps -o command= -p "$PID")" ;;
esac
if [ -n "$QUARANTINED" ]; then
  left="$(xattr -r "$APP" 2>/dev/null | grep -c quarantine)"
  [ "$left" = 0 ] && ok "launcher cleared the quarantine flag off every file" || bad "$left files still quarantined"
fi

DEF="$(get /api/defaults)"
for k in has_exiftool has_ffmpeg has_pillow; do
  [ "$(printf '%s' "$DEF" | field "$k")" = True ] && ok "$k" || bad "$k is false"
done

# ---------------------------------------------------------------------- scan
SCAN="$(post /api/scan "{\"card\": \"$CARD\"}")"
printf '%s' "$SCAN" | py -c '
import json, sys
want = {"DSC00001.JPG": ("2026-10-04", "exif"), "DSC00002.JPG": ("2026-10-05", "exif"),
        "DSC00001.ARW": ("2026-10-04", None), "C0001.MP4": ("2026-10-04", "quicktime")}
if sys.argv[1]:
    want["DSC00003.HIF"] = ("2026-10-04", "exif")
got = {f["name"]: (f["day"], f["date_source"]) for f in json.load(sys.stdin)["files"]}
bad = [n for n, (day, src) in want.items()
       if n not in got or got[n][0] != day or (src and got[n][1] != src)]
for n in sorted(got):
    print("        %-14s %s  (%s)" % (n, got[n][0], got[n][1]))
sys.exit(1 if bad or len(got) != len(want) else 0)
' "$HAVE_HIF" && ok "scan found every file under its shooting date" || bad "scan result is wrong"

# -------------------------------------------------------------------- import
IMPORT="{\"card\": \"$CARD\", \"days\": [\"2026-10-04\"], \"kinds\": [\"jpeg\", \"raw\", \"video\"],
  \"dest\": \"$OUT\", \"layout\": \"by-day\", \"keep_originals\": true,
  \"photo\": {\"enabled\": true, \"long_edge\": 2560, \"quality\": 85, \"strip_gps\": true},
  \"video\": {\"enabled\": true, \"preset\": \"reels\", \"mode\": \"quality\"}}"
run_import() {
  post /api/import "$IMPORT" >/dev/null || { bad "import was refused"; return 1; }
  local state=""
  for _ in $(seq 1 600); do
    PROG="$(get /api/progress)"; state="$(printf '%s' "$PROG" | field state)"
    case "$state" in done|error|cancelled) break ;; esac
    perl -e 'select(undef,undef,undef,0.5)'
  done
  [ "$state" = done ] && return 0
  bad "import ended as: $state"; printf '%s' "$PROG" | field errors; return 1
}
echo "Importing"
run_import && ok "import finished without errors"

D="$OUT/2026-10-04"
check "original photo copied byte for byte"  cmp "$J/DSC00001.JPG" "$D/DSC00001.JPG"
check "RAW copied byte for byte"             cmp "$J/DSC00001.ARW" "$D/DSC00001.ARW"
check "original video copied byte for byte"  cmp "$V" "$D/C0001.MP4"
check "the other day's photo was left out"   test -z "$(find "$OUT" -name 'DSC00002*')"

dims() { py -c 'import sys; from PIL import Image; print("%dx%d" % Image.open(sys.argv[1]).size)' "$1" 2>/dev/null; }
tag()  { /usr/bin/perl "$RES/vendor/exiftool/exiftool" -s3 "-$1" "$2" 2>/dev/null; }
S1="$D/Social/DSC00001.jpg"
[ "$(dims "$S1")" = 2560x1707 ] && ok "photo resized to 2560x1707" || bad "resized photo is $(dims "$S1")"
[ "$(tag DateTimeOriginal "$S1")" = "2026:10:04 10:11:12" ] && ok "capture date kept" || bad "capture date lost"
[ -z "$(tag GPSLatitude "$S1")" ] && ok "GPS stripped" || bad "GPS still present"
if [ -n "$HAVE_HIF" ]; then
  # sips rounds the short edge differently from Pillow, so only the long edge is fixed.
  case "$(dims "$D/Social/DSC00003.jpg")" in
    2560x*) ok "HIF converted and resized" ;;
    *) bad "HIF result is $(dims "$D/Social/DSC00003.jpg")" ;;
  esac
fi
VO="$D/Social/C0001-reels.mp4"
VDIM="$("$TOOLS/ffprobe" -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$VO" 2>/dev/null)"
[ "$VDIM" = 1920,1080 ] && ok "4K video compressed to 1080p" || bad "compressed video is '$VDIM'"

# A second pass over the same card has to leave everything exactly as it is.
BEFORE="$(cd "$OUT" && find . -type f -exec stat -f '%N %z %m' {} + | sort)"
run_import && ok "second import finished without errors"
AFTER="$(cd "$OUT" && find . -type f -exec stat -f '%N %z %m' {} + | sort)"
[ "$BEFORE" = "$AFTER" ] && ok "importing twice changed nothing" || bad "the second import changed files"

# ---------------------------------------------------------------------- quit
post /api/quit '{}' >/dev/null
for _ in $(seq 1 100); do kill -0 "$PID" 2>/dev/null || break; perl -e 'select(undef,undef,undef,0.1)'; done
if kill -0 "$PID" 2>/dev/null; then bad "server did not quit"; else ok "server quit when asked"; PID=""; fi

echo "Launcher log:"
grep '^launcher:' "$LOG" | sed 's/^/        /'
echo
if [ "$FAILS" = 0 ]; then echo "PASS"; else echo "$FAILS check(s) failed"; exit 1; fi
