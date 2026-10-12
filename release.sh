#!/bin/bash
# Cut a release: build the app, test it, write the update manifest, and publish
# the lot as a GitHub release.
#
#   ./release.sh 1.4.2             build and test into release/
#   ./release.sh 1.4.2 --publish   and put it on GitHub
#   (--no-test skips the end-to-end test)
#
# A release is two things in one folder:
#   SonyGrab.zip                the whole app, for a first install
#   MANIFEST + the code         what installed copies update themselves from
#
# Installed copies look at <repo>/releases/latest/download on every launch, so
# publishing is all it takes to reach them. Only the ~100 KB of code travels.
# The app itself, with its front end and 160 MB of bundled
# python/ffmpeg/exiftool, stays where it is. That part is versioned separately
# (VENDOR_REV), so a copy can say "this one needs a fresh install" instead of
# running new code inside an app that is too old for it.
set -euo pipefail
cd "$(dirname "$0")"

CODE=(core.py photo.py compress.py pipeline.py server.py ui.html)
VENDOR_REV=4                            # bump when vendor/ or the app around the code changes

die() { echo "$*" >&2; exit 1; }

VERSION=""; PUBLISH=""; TEST=1
for a in "$@"; do
  case "$a" in
    --publish) PUBLISH=1 ;;
    --no-test) TEST="" ;;
    -*) echo "unknown option: $a" >&2; exit 2 ;;
    *) VERSION="$a" ;;
  esac
done
case "$VERSION" in
  ""|*[!0-9.]*)
    echo "usage: ./release.sh <version> [--publish] [--no-test]     version like 1.4.2" >&2
    exit 2 ;;
esac

# Same rule the launcher uses to decide whether an update is worth taking.
version_newer() {
  [ "$1" != "$2" ] &&
    [ "$(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n | tail -1)" = "$1" ]
}

# Where installed copies will look. Worked out from the git remote, so the
# address is not written down anywhere else.
SLUG="$(git remote get-url origin 2>/dev/null |
        sed -E 's#^(https://github\.com/|git@github\.com:)##; s#\.git$##' || true)"
URL="${SONYGRAB_UPDATE_URL:-}"
if [ -z "$URL" ]; then
  [ -n "$SLUG" ] || die "No git remote called origin, so there is nowhere to publish. Set SONYGRAB_UPDATE_URL to build for another server."
  URL="https://github.com/$SLUG/releases/latest/download"
fi

if [ -n "$PUBLISH" ]; then
  command -v gh >/dev/null 2>&1 || die "Publishing needs the GitHub CLI: brew install gh"
  [ -n "$SLUG" ] || die "No git remote called origin to publish to."
  [ -z "$(git status --porcelain)" ] || die "There are uncommitted changes. Commit them first, so the release matches a commit."
  LATEST="$(gh release view --json tagName -q .tagName 2>/dev/null | sed 's/^v//' || true)"
  if [ -n "$LATEST" ]; then
    version_newer "$VERSION" "$LATEST" ||
      die "$VERSION is not newer than $LATEST, the latest release. Installed copies only ever move forward, so they would ignore it."
  fi
fi

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/sonygrab-release.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

# Built somewhere else on purpose: ./SonyGrab.app may be running right now.
echo "Building $VERSION"
./build_app.sh --out "$STAGE/SonyGrab.app" --version "$VERSION" --update-url "$URL" | tail -1

if [ -n "$TEST" ]; then
  echo "Testing it"
  ./smoke_test.sh "$STAGE/SonyGrab.app" || die "The end-to-end test failed, so nothing was released."
fi

OUT="release"
rm -rf "$OUT"; mkdir -p "$OUT"
cp "${CODE[@]}" "$OUT/"

# Plain lines rather than JSON so the launcher can read it with awk and needs
# no interpreter before it has decided which interpreter to use.
{
  echo "version $VERSION"
  echo "vendor $VENDOR_REV"
  for f in "${CODE[@]}"; do
    echo "file $(shasum -a 256 "$f" | cut -d' ' -f1) $f"
  done
} > "$OUT/MANIFEST"

# Files only, with no extended attributes. Left in, each attribute becomes a
# hidden "._name" entry in the zip, and the Mac unzipping it can turn one of
# those into a real extra file inside the app, which breaks its seal.
ditto -c -k --norsrc --noextattr --keepParent "$STAGE/SonyGrab.app" "$OUT/SonyGrab.zip"
if unzip -l "$OUT/SonyGrab.zip" | grep -qE '/\._|__MACOSX'; then
  die "The zip still carries hidden metadata entries, so the unzipped app would not open."
fi

echo "Release $VERSION is in $OUT/"
sed 's/^/  /' "$OUT/MANIFEST"
echo "  SonyGrab.zip  $(du -h "$OUT/SonyGrab.zip" | cut -f1)"

if [ -z "$PUBLISH" ]; then
  echo
  echo "Not published. Add --publish to put it on GitHub."
  exit 0
fi

git push -q origin HEAD
# gh uploads the files to a draft and only then makes it public, so nobody
# ever fetches a release that is half there.
gh release create "v$VERSION" "$OUT"/* \
    --target "$(git rev-parse HEAD)" --latest \
    --title "SonyGrab $VERSION" \
    --notes "Download **SonyGrab.zip** below. Install steps are in the [README](https://github.com/$SLUG#download).

Copies that are already installed update themselves the next time they are opened." >/dev/null

# Read it back the way an installed copy will. GitHub can take a few seconds
# to start serving a new release under the "latest" address.
LIVE=""
for _ in 1 2 3 4 5 6 7 8; do
  if curl -fsSL --max-time 20 "$URL/MANIFEST" 2>/dev/null | cmp -s - "$OUT/MANIFEST"; then LIVE=1; break; fi
  sleep 5
done
[ -n "$LIVE" ] || die "Published, but $URL/MANIFEST is not serving the new manifest yet. Check the release page."

echo
echo "Published. Installed copies pick it up the next time they are opened."
echo "  Download:  https://github.com/$SLUG/releases/latest/download/SonyGrab.zip"
echo "  Page:      https://github.com/$SLUG/releases/latest"
