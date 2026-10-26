#!/usr/bin/env bash
# upload-hd-assets.sh - put the HD art on a GitHub release of this (public) repo and write the
# hd-art.json that launchers (installer/update-check.ps1) and installers read.
#
#   tools/upload-hd-assets.sh --dir DIR [--tag hd-art-1] [--dry-run]
#   tools/upload-hd-assets.sh --from-uo-offline-dev DIR [--tag hd-art-1] [--dry-run]
#
# DIR holds UOSmallz-HDArt-2x.zip and UOSmallz-HDAnim-N.uoanim (tools/hd-art in uo-offline-dev
# makes them). --from-uo-offline-dev first downloads the same files from the private
# uo-offline-dev release "uo-offline-hd-art" (UOOffline-*.{zip,uoanim}, needs gh logged in with
# access to it) into DIR under their UOSmallz-* names.
#
# Steps: checks every file is under 2 GiB (GitHub's limit per release asset), hashes them, writes
# hd-art.json in the repo root ({ release, file, size, sha256, creatures: { frames, files } }),
# then (not with --dry-run) creates the release with --latest=false (players' client update reads
# releases/latest, which must stay the client release) and uploads the files plus a copy of
# hd-art.json. An existing asset of the same name is never replaced: a new pack gets a new tag
# (hd-art-2, ...). Release assets, not workflow artifacts (Actions storage is 1 GB).
#
# After the upload: check every URL answers anonymously (the script does, with curl -I), then
# commit hd-art.json and push. Launchers move to the release only when hd-art.json on main names it.
set -euo pipefail
REPO=wesleysnoe-dev/uosmallz-client
SRC_REPO=wesleysnoe-dev/uo-offline-dev
SRC_TAG=uo-offline-hd-art
TAG=hd-art-1
DIR=""; FROM_SRC=0; DRY=0
MAX=$(( 2 * 1024 * 1024 * 1024 - 1 ))
here="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$here/hd-art.json"

while (( $# )); do
  case "$1" in
    --dir) DIR="$2"; shift 2 ;;
    --from-uo-offline-dev) DIR="$2"; FROM_SRC=1; shift 2 ;;
    --tag) TAG="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --manifest) MANIFEST="$2"; shift 2 ;;
    -h|--help) sed -n '2,23p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$DIR" ]] || { echo "--dir or --from-uo-offline-dev is needed" >&2; exit 2; }
[[ "$TAG" =~ ^hd-art-[0-9]{1,6}$ ]] || { echo "the tag must be hd-art-N (the launcher accepts nothing else)" >&2; exit 2; }
mkdir -p "$DIR"

if (( FROM_SRC )); then
  echo "Downloading $SRC_REPO $SRC_TAG into $DIR (about 4.7 GB)..."
  gh release download "$SRC_TAG" -R "$SRC_REPO" -D "$DIR" -p 'UOOffline-HDArt-*.zip' -p 'UOOffline-HDAnim-*.uoanim' --skip-existing
  for f in "$DIR"/UOOffline-*; do [[ -f "$f" ]] && mv -f "$f" "$DIR/UOSmallz-${f##*/UOOffline-}"; done
  # the release's own digests must still hold after the rename
  gh release view "$SRC_TAG" -R "$SRC_REPO" --json assets -q '.assets[] | "\(.digest|ltrimstr("sha256:"))  \(.name)"' \
    | sed 's/  UOOffline-/  UOSmallz-/' | (cd "$DIR" && sha256sum -c -)
fi

shopt -s nullglob
packs=("$DIR"/UOSmallz-HDArt-*.zip)
anims=("$DIR"/UOSmallz-HDAnim-*.uoanim)
(( ${#packs[@]} == 1 )) || { echo "expected exactly one UOSmallz-HDArt-*.zip in $DIR, found ${#packs[@]}" >&2; exit 1; }
mapfile -t anims < <(printf '%s\n' "${anims[@]}" | sort -V)
for f in "${packs[@]}" "${anims[@]}"; do
  s=$(stat -c %s "$f")
  (( s <= MAX )) || { echo "$f is $s bytes; a release asset must be under 2 GiB" >&2; exit 1; }
done

frames="$(python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1]))["creatures"]["frames"])
except Exception: print(0)' "$MANIFEST" 2>/dev/null || echo 0)"
echo "Hashing ${#packs[@]} pack and ${#anims[@]} creature files..."
python3 - "$TAG" "$frames" "$MANIFEST.new" "${packs[0]}" "${anims[@]}" <<'PY'
import hashlib, json, os, sys
tag, frames, out, pack, anims = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5:]
def entry(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""): h.update(b)
    return {"file": os.path.basename(p), "size": os.path.getsize(p), "sha256": h.hexdigest()}
j = {"release": tag, **entry(pack)}
if anims:
    j["creatures"] = {"frames": frames, "files": [entry(a) for a in anims]}
with open(out, "w", newline="\n") as f:
    f.write(json.dumps(j, indent=2) + "\n")
PY
mv -f "$MANIFEST.new" "$MANIFEST"
echo "Wrote $MANIFEST:"; cat "$MANIFEST"

assets=("${packs[0]}" "${anims[@]}")
echo
echo "Release $REPO $TAG would carry:"
for f in "${assets[@]}"; do printf '  %-28s %12s bytes\n' "${f##*/}" "$(stat -c %s "$f")"; done
printf '  %-28s %12s bytes\n' hd-art.json "$(stat -c %s "$MANIFEST")"
if (( DRY )); then echo; echo "--dry-run: nothing uploaded."; exit 0; fi

if ! gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
  gh release create "$TAG" -R "$REPO" --latest=false --title "UO Smallz HD art ($TAG)" \
    --notes "HD art for the UO Smallz client: the 2x pack (HDArt) and the creature packs (HDArt/anim), with hd-art.json (sizes and SHA-256). The launcher and installers download these; nothing to do by hand."
fi
have="$(gh release view "$TAG" -R "$REPO" --json assets -q '.assets[].name')"
for f in "${assets[@]}" "$MANIFEST"; do
  n="${f##*/}"
  if grep -qxF "$n" <<< "$have"; then echo "$n is already on $TAG; left as it is (a new pack needs a new tag)."; continue; fi
  echo "Uploading $n..."
  gh release upload "$TAG" -R "$REPO" "$f"
done

echo "Checking every file answers without a login..."
for f in "${assets[@]}" "$MANIFEST"; do
  u="https://github.com/$REPO/releases/download/$TAG/${f##*/}"
  code="$(curl -sIL -o /dev/null -w '%{http_code}' "$u")"
  echo "  $code $u"; [[ "$code" == 200 ]] || { echo "not reachable anonymously: $u" >&2; exit 1; }
done
echo "Done. Commit hd-art.json and push it to main to move launchers to $TAG."
