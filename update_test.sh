#!/bin/bash
# Rehearsal of releasing and self-updating, against a stand-in for GitHub that
# runs on this Mac. Cuts real releases with release.sh from a private copy of
# this folder, installs the first one, then walks an installed copy through
# every case the updater has to get right.
#
#   ./update_test.sh
#
# Like smoke_test.sh it uses its own HOME and opens no browser window, and it
# publishes nothing. Needs vendor/ (see fetch_vendor.sh). Takes a few minutes,
# most of it building.
set -u
cd "$(dirname "$0")"
[ -x vendor/python/bin/python3 ] || { echo "run ./fetch_vendor.sh first" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/sonygrab-update.XXXXXX")"
PROJ="$WORK/proj"; SERVED="$WORK/served"; FAKE_HOME="$WORK/home"; APPS="$WORK/Applications"
mkdir -p "$PROJ" "$SERVED" "$FAKE_HOME" "$APPS" "$WORK/tmp"
SRV=""; PID=""
cleanup() {
  [ -n "$SRV" ] && kill "$SRV" 2>/dev/null
  hdiutil detach -quiet "$WORK/mnt" 2>/dev/null
  [ -n "$PID" ] && kill "$PID" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

FAILS=0
ok()  { printf '  ok    %s\n' "$*"; }
bad() { printf '  FAIL  %s\n' "$*"; FAILS=$((FAILS + 1)); }
nap() { perl -e 'select(undef,undef,undef,0.1)'; }

# A private copy to cut releases from, so this folder is never touched.
for f in core.py photo.py compress.py pipeline.py server.py ui.html SonyGrab.m SonyGrab.icns \
         build_app.sh release.sh smoke_test.sh dmg.DS_Store THIRD_PARTY.md licenses vendor; do
  cp -Rc "$f" "$PROJ/" 2>/dev/null || cp -R "$f" "$PROJ/"
done

# GitHub answers a release link with a redirect to the file. So does this.
PY="$PWD/vendor/python/bin/python3"
PORT="$("$PY" -B -E -s -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
"$PY" -B -E -s - "$PORT" "$SERVED" <<'PYEOF' &
import os, sys, http.server
port, root = int(sys.argv[1]), sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def answer(self, code, body=b"", location=None):
        self.send_response(code)
        if location: self.send_header("Location", location)
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def do_GET(self):
        p = self.path.split("?")[0]
        if p.startswith("/latest/download/"):
            return self.answer(302, location="/assets/" + p.rsplit("/", 1)[1])
        f = os.path.join(root, os.path.basename(p))
        if p.startswith("/assets/") and os.path.isfile(f):
            return self.answer(200, open(f, "rb").read())
        self.answer(404)
http.server.ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()
PYEOF
SRV=$!
export SONYGRAB_UPDATE_URL="http://127.0.0.1:$PORT/latest/download" TMPDIR="$WORK/tmp"

APP="$APPS/SonyGrab.app"
STORE="$FAKE_HOME/Library/Application Support/SonyGrab/app"
LOG="$FAKE_HOME/Library/Logs/SonyGrab.log"
release() { (cd "$PROJ" && ./release.sh "$@" >"$WORK/release.log" 2>&1) || { bad "release.sh $* failed"; tail -5 "$WORK/release.log"; }; }
publish() { rm -f "$SERVED"/*; cp "$1"/* "$SERVED/"; }
launch()  { env -i HOME="$FAKE_HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin BROWSER=/usr/bin/true \
              /bin/bash "${1:-$APP}/Contents/Resources/launch.sh" & }
up() {
  PID=""
  for _ in $(seq 1 150); do [ -s "$FAKE_HOME/.sonygrab.pid" ] && break; nap; done
  PID="$(sed -n 1p "$FAKE_HOME/.sonygrab.pid" 2>/dev/null)"
  URL="$(sed -n 2p "$FAKE_HOME/.sonygrab.pid" 2>/dev/null)"; BASE="${URL%%/\?*}"; TOKEN="${URL##*t=}"
}
quit() {
  curl -fsS -H "X-Token: $TOKEN" -d '{}' "$BASE/api/quit" >/dev/null
  for _ in $(seq 1 100); do kill -0 "$PID" 2>/dev/null || break; nap; done
  for _ in $(seq 1 50); do [ -e "$FAKE_HOME/.sonygrab.pid" ] || break; nap; done
  PID=""
}
# The version of the code the server is really running: the VERSION file in
# the folder it was started from.
running() { cat "$(lsof -a -p "$PID" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')/VERSION" 2>/dev/null; }
stored()  { cat "$STORE/VERSION" 2>/dev/null || echo none; }
expect()  { [ "$(running)" = "$1" ] && ok "$2 (ran $(running), stored update: $(stored))" \
              || bad "$2: ran $(running), expected $1 (stored update: $(stored))"; }
sealed()  { codesign --verify --deep --strict "$APP" 2>/dev/null; }

echo "Release 1.0.0, with the end-to-end test"
release 1.0.0
grep -q '^PASS$' "$WORK/release.log" && ok "release.sh built it and its end-to-end test passed" || bad "no PASS from the end-to-end test"
cp -R "$PROJ/release" "$WORK/rel-1.0.0"; publish "$PROJ/release"

echo "First install, from the published disk image"
mkdir "$WORK/mnt"
curl -fsSL -o "$WORK/tmp/dl.dmg" "$SONYGRAB_UPDATE_URL/SonyGrab.dmg" &&
  hdiutil attach -quiet -nobrowse -readonly -mountpoint "$WORK/mnt" "$WORK/tmp/dl.dmg" &&
  ditto "$WORK/mnt/SonyGrab.app" "$APP"
hdiutil detach -quiet "$WORK/mnt" 2>/dev/null
sealed && ok "the downloaded app's seal verifies" || bad "the downloaded app's seal does not verify"
launch; up; expect 1.0.0 "same version published: nothing to do"; quit

echo "Release 1.0.1, with a visible change"
echo '<!-- marker-101 -->' >> "$PROJ/ui.html"
release 1.0.1 --no-test; publish "$PROJ/release"
launch; up; expect 1.0.1 "newer release is picked up through the redirect"
curl -fsS "$BASE/" | grep -q "marker-101" && ok "the running app serves the new page" || bad "new page not served"
[ "$(cat "$APP/Contents/Resources/app/VERSION")" = 1.0.0 ] && sealed \
  && ok "the update went into the Library; the app itself is untouched and still sealed" \
  || bad "the app bundle was changed by the update"
quit

echo "An old release served again"
publish "$WORK/rel-1.0.0"; launch; up; expect 1.0.1 "older release is ignored"

echo "A newer release appears while the app is running"
echo '<!-- marker-102 -->' >> "$PROJ/ui.html"
release 1.0.2 --no-test; publish "$PROJ/release"
launch; wait $! 2>/dev/null
[ "$(stored)" = 1.0.1 ] && kill -0 "$PID" 2>/dev/null \
  && ok "a second launch leaves the running copy and its code alone" || bad "the running copy was disturbed (stored: $(stored))"
quit; launch; up; expect 1.0.2 "it updates on the next start instead"; quit

echo "A file that does not match the manifest"
release 1.0.3 --no-test; publish "$PROJ/release"; echo "# damaged" >> "$SERVED/core.py"
launch; up; expect 1.0.2 "release with a mismatched file is refused"; quit
grep -q "download or checksum failed" "$LOG" && ok "and the log says why" || bad "no log line about the checksum"

echo "A release that needs a newer app than the one installed"
publish "$PROJ/release"; sed -i '' 's/^vendor .*/vendor 99/' "$SERVED/MANIFEST"
launch; up; expect 1.0.2 "it is refused"; quit
grep -q "needs a newer app" "$LOG" && ok "and the log says to install again" || bad "no log line about needing a newer app"

echo "A newer app installed over an older stored update"
(cd "$PROJ" && ./build_app.sh --out "$WORK/newer/SonyGrab.app" --version 1.0.9 --update-url "$SONYGRAB_UPDATE_URL" >/dev/null 2>&1)
publish "$WORK/rel-1.0.0"
launch "$WORK/newer/SonyGrab.app"; up; expect 1.0.9 "the app's own newer code wins over the stored 1.0.2"; quit

echo "An update address that is neither HTTPS nor this Mac"
cp -R "$APP" "$WORK/plain.app"
sed -i '' "s|^url = .*|url = http://localhost:$PORT/latest/download|" "$WORK/plain.app/Contents/Resources/update.conf"
rm -rf "$STORE"; publish "$PROJ/release"
launch "$WORK/plain.app"; up; expect 1.0.0 "it is not used at all"; quit

echo "The server is gone"
kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; SRV=""
launch; up
kill -0 "$PID" 2>/dev/null && ok "the app still starts" || bad "the app did not start"
quit
sealed && ok "after all of that the installed app is still exactly as built" || bad "the installed app's seal no longer verifies"

echo "Update lines the launcher logged:"
grep -E '^update' "$LOG" | sed 's/^/        /'
echo
if [ "$FAILS" = 0 ]; then echo "PASS"; else echo "$FAILS check(s) failed"; exit 1; fi
