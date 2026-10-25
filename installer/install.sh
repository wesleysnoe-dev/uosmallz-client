#!/usr/bin/env bash
# UO Smallz player installer (Linux x64).
# Needs: curl, unzip, sha256sum, python3, 7z (p7zip, for the classic map) and
# one RAR5 extractor for the game data: unar, unrar or 7zz (p7zip cannot read RAR5).
set -euo pipefail
HOST=uosmallz.duckdns.org; PORT=2593; VER=7.0.23.1
# The latest client, checked against its release's SHA256SUMS.txt (as install.ps1 does on Windows).
CLIENT_URL=https://github.com/wesleysnoe-dev/uosmallz-client/releases/latest/download/UOSmallz-Client-linux-x64.zip
SUMS_URL=https://github.com/wesleysnoe-dev/uosmallz-client/releases/latest/download/SHA256SUMS.txt
# HD art (tools/hd-art in uo-offline-dev): ~0.5 GB from the UO Smallz server itself into $ROOT/HDArt
# (the client reads it from beside its folder), checked against hd-art.json in this repo. Fetched
# again only when hd-art.json names a new pack. INSTALL_HD_ART=0 to skip. The HD creatures (several
# .uoanim files of about 1 GB, listed in hd-art.json under "creatures") go to $ROOT/HDArt/anim the
# same way; INSTALL_HD_CREATURES=0 to skip them.
HD_ART_MANIFEST=https://raw.githubusercontent.com/wesleysnoe-dev/uosmallz-client/main/hd-art.json
HD_ART_BASE=http://uosmallz.duckdns.org:2595/
# Same mirror, file and hash as the UO Offline installer.
DATA_URL=https://mirror.ashkantra.de/fullclients/7.0.23.1.exe
DATA_SHA=23b0548252bb4e6f39afbddac2e64f8deb862fbfaccb1303b87895d295e01839
T2A_INSTALLER_URL="https://download.uosecondage.com/UOSA_Client_Setup.exe"
T2A_INSTALLER_SHA256="674ec3cce9621bd8c1a8f2f69070e64e63191ce73d6f297236bf8f3b89d41ddf"
INSTALL_T2A_MAP="${INSTALL_CLASSIC_MAP:-0}"
ROOT="${1:-$HOME/.local/share/uosmallz}"
UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36"
say()  { echo "    $*"; }
ok()   { echo "[ok] $*"; }
warn() { echo "[warn] $*"; }
die()  { echo "[error] $*"; exit 1; }
banner(){ echo; echo "== $* =="; }
verify_pinned() { echo "$2  $1" | sha256sum -c --quiet - || { rm -f "$1"; die "SHA256 mismatch for $3; file deleted."; }; }
for c in curl unzip sha256sum python3; do command -v $c >/dev/null || die "Please install $c"; done

mkdir -p "$ROOT/Client" "$ROOT/UOData"
banner "Game client (TazUO)"
here="$(cd "$(dirname "$0")" && pwd)"; zip="$here/UOSmallz-Client-linux-x64.zip"
if [ ! -f "$zip" ]; then
  zip="$ROOT/UOSmallz-Client-linux-x64.zip"; say "Downloading the latest client..."
  curl -fL -A "$UA" -o "$zip" "$CLIENT_URL"
  curl -fsSL -A "$UA" -o "$ROOT/SHA256SUMS.txt" "$SUMS_URL"
  (cd "$ROOT" && grep ' UOSmallz-Client-linux-x64.zip$' SHA256SUMS.txt | sha256sum -c --quiet -) \
    || { rm -f "$zip" "$ROOT/SHA256SUMS.txt"; die "SHA256 mismatch for the client download; file deleted."; }
  rm -f "$ROOT/SHA256SUMS.txt"
fi
unzip -qo "$zip" -d "$ROOT/Client"; chmod +x "$ROOT/Client/TazUO" 2>/dev/null || true
ok "Client: $ROOT/Client/TazUO"

banner "Ultima Online game data ($VER)"
find_data() { local t; t="$(find "$1" -name tiledata.mul -print -quit 2>/dev/null || true)"; [ -n "$t" ] && dirname "$t"; return 0; }
UO_DATA="$(find_data "$ROOT/UOData")"
if [ -z "$UO_DATA" ] && [ -n "${UO_DIR:-}" ]; then UO_DATA="$(find_data "$UO_DIR")"; fi
if [ -z "$UO_DATA" ]; then
  sfx="$ROOT/UOData/$VER.exe"; dest="$ROOT/UOData/$VER"; mkdir -p "$dest"
  say "Downloading UO $VER game data (~930 MB, community mirror; EA content)..."
  curl -fL -A "$UA" -o "$sfx" "$DATA_URL"
  verify_pinned "$sfx" "$DATA_SHA" "the UO data download"
  done_x=0
  command -v unrar >/dev/null && unrar x -y -inul "$sfx" "$dest/" && done_x=1 || true
  [ $done_x = 0 ] && command -v 7zz >/dev/null && 7zz x -y "-o$dest" "$sfx" >/dev/null && done_x=1 || true
  if [ $done_x = 0 ] && command -v unar >/dev/null; then
    off="$(python3 - "$sfx" <<'PY'
import sys
sig=b"Rar!\x1a\x07\x01\x00"; data=open(sys.argv[1],"rb").read(64<<20); i=data.find(sig); print(i if i>=0 else "")
PY
)"
    [ -n "$off" ] && tail -c "+$((off + 1))" "$sfx" > "$sfx.rar" && unar -q -f -D -o "$dest" "$sfx.rar" >/dev/null && done_x=1 || true
    rm -f "$sfx.rar"
  fi
  [ $done_x = 1 ] || die "Could not extract the game data. Install unar (or unrar / 7zz) and re-run."
  rm -f "$sfx"
  UO_DATA="$(find_data "$ROOT/UOData")"
  [ -n "$UO_DATA" ] || die "Extracted, but tiledata.mul was not found."
fi
ok "UO data: $UO_DATA"

# Felucca map art: the server's, as in install.ps1 (see its notes). The UO
# Smallz server runs the modern map with the Magincia island pasted in from
# the classic art: an install with the classic map gets the modern files put
# back, Magincia is pasted from the same sources (land: map0x.mul from the
# 7.0.23.1 data; statics: the UO Second Age client) with map-merge.ps1
# (needs pwsh), and the result is checked against the server's files.
# INSTALL_CLASSIC_MAP=1 still swaps in the whole classic art.
T2A_SRC_DIR="$ROOT/t2a-src"
MAP_FILES="map0.mul statics0.mul staidx0.mul"
declare -A SERVER_MAP_SHA=(
  [map0.mul]=64e5a0b530e071da69e5f698680b0e0043a49aa9aa025322781d4f55b4dfcbc4
  [statics0.mul]=2e362abf4cc55521bd2f673d6f71577fd7b42f9a3b4c293f5a998a7cfb5657c4
  [staidx0.mul]=e8f9d96eaa33775428cf260b2a70146c8a6e1af98caac554642484718566789d
)
# The three classic map files from the UO Second Age client, extracted to
# $T2A_SRC_DIR/uosa-install: CLASSIC[file] = path. Fails (warned) without them.
declare -A CLASSIC
get_classic_map_files() {
  command -v 7z >/dev/null || { warn "7z not found: cannot read the classic map files (install p7zip and re-run)."; return 1; }
  mkdir -p "${T2A_SRC_DIR}"
  local uosa_exe="${T2A_SRC_DIR}/UOSA_Client_Setup.exe"
  if [[ ! -f "${uosa_exe}" ]]; then
    say "Downloading UO Second Age client (~349 MB, EA content via uosecondage.com) for its classic map art..."
    curl -fL --progress-bar -A "$UA" -o "${uosa_exe}" "${T2A_INSTALLER_URL}"
  fi
  verify_pinned "${uosa_exe}" "${T2A_INSTALLER_SHA256}" "the UO Second Age installer (UOSA_Client_Setup.exe)"
  local extract_dir="${T2A_SRC_DIR}/uosa-install"; mkdir -p "${extract_dir}"
  say "Extracting the classic map files with 7z..."
  7z x -y "-o${extract_dir}" "${uosa_exe}" map0.mul statics0.mul staidx0.mul >/dev/null || true
  local missing=0 f src
  for f in ${MAP_FILES}; do
    src="$(find "${extract_dir}" -maxdepth 4 -name "${f}" -print -quit 2>/dev/null || true)"
    if [[ -z "${src}" ]]; then warn "Classic ${f} not found after extract."; missing=1; else CLASSIC[${f}]="${src}"; fi
  done
  [[ "${missing}" == "0" ]]
}

swap_t2a_map() {
  banner "Installing classic Felucca map art (INSTALL_CLASSIC_MAP=1)"
  warn "The UO Smallz server runs the modern map with intact Magincia: with the whole classic art, parts of your map will not match it."
  local backup_dir="${UO_DATA}/_backup-modern-map" f
  if [[ -f "${backup_dir}/map0.mul" ]]; then say "Classic map already swapped (modern backup exists). Skipping."; return; fi
  get_classic_map_files || { warn "Aborting the classic map swap; modern map kept."; return; }
  local -n src_path=CLASSIC
  mkdir -p "${backup_dir}"
  for f in map0.mul statics0.mul staidx0.mul radarcol.mul tiledata.mul; do
    [[ -f "${UO_DATA}/${f}" ]] && cp -f "${UO_DATA}/${f}" "${backup_dir}/${f}"
  done
  ok "Backed up modern map -> ${backup_dir}"
  for f in map0.mul statics0.mul staidx0.mul; do cp -f "${src_path[${f}]}" "${UO_DATA}/${f}"; done
  rm -rf "${T2A_SRC_DIR}/uosa-install"
  ok "Classic Felucca map art installed (intact Magincia)."
  # The 2002-area merge is OFF by default: the server map is the classic swap
  # without it. UOSMALLZ_MAP_MERGE=1 turns it on (only if the server is merged too).
  [[ "${UOSMALLZ_MAP_MERGE:-0}" == "1" ]] || return 0
  if command -v pwsh >/dev/null && [[ -f "$here/map-merge.ps1" ]]; then
    pwsh -NoProfile -File "$here/map-merge.ps1" -DataDir "${UO_DATA}" -NoPause && ok "2002 areas merged." || warn "map-merge.ps1 failed."
  else
    warn "PowerShell (pwsh) not found: the Solen hives / faction strongholds / Khaldun areas were not merged. Install pwsh and run: pwsh map-merge.ps1 -DataDir \"${UO_DATA}\" -NoPause"
  fi
}

# An install that has the classic map: the modern files back from
# _backup-modern-map, the classic ones to _backup-classic-map-retired.
restore_modern_map() {
  local backup_dir="${UO_DATA}/_backup-modern-map" retired="${UO_DATA}/_backup-classic-map-retired" f
  if [[ ! -f "${backup_dir}/map0.mul" ]]; then say "Modern Felucca map art in use."; return 0; fi
  mkdir -p "${retired}"
  for f in ${MAP_FILES}; do
    cp -f "${UO_DATA}/${f}" "${retired}/${f}"
    cp -f "${backup_dir}/${f}" "${UO_DATA}/${f}"
  done
  mv "${backup_dir}" "${backup_dir}.restored-$(date +%Y%m%d-%H%M%S)"
  ok "Modern Felucca map art put back (the classic files are in _backup-classic-map-retired)."
}

# Intact Magincia, pasted the way the server's was (see install.ps1).
paste_magincia() {
  if [[ -f "${UO_DATA}/magincia-paste.txt" ]]; then say "Intact Magincia already on the map."; return 0; fi
  command -v pwsh >/dev/null || { warn "PowerShell (pwsh) not found: Magincia stays bare ground (not as on the server). Install pwsh and run install.sh again."; return 0; }
  local retired="${UO_DATA}/_backup-classic-map-retired" src="${UO_DATA}/_magincia-source" extracted=0 code=0
  if [[ -f "${retired}/statics0.mul" && -f "${retired}/staidx0.mul" ]]; then
    CLASSIC=([map0.mul]="${retired}/map0.mul" [statics0.mul]="${retired}/statics0.mul" [staidx0.mul]="${retired}/staidx0.mul")
  else
    get_classic_map_files || { warn "Magincia stays bare ground (not as on the server). Run install.sh again to retry."; return 0; }
    extracted=1
  fi
  mkdir -p "${src}"
  cp -f "${CLASSIC[statics0.mul]}" "${src}/statics0.mul"
  cp -f "${CLASSIC[staidx0.mul]}" "${src}/staidx0.mul"
  if [[ -f "${UO_DATA}/map0x.mul" ]]; then
    cp -f "${UO_DATA}/map0x.mul" "${src}/map0.mul"
  else
    warn "No map0x.mul in your UO folder: Magincia's land comes from the classic map instead (the shore water depth differs from the server's)."
    cp -f "${CLASSIC[map0.mul]}" "${src}/map0.mul"
  fi
  say "Putting intact Magincia onto the modern map..."
  pwsh -NoProfile -File "$here/map-merge.ps1" -Magincia -From "${src}" -DataDir "${UO_DATA}" -NoPause >/dev/null || code=$?
  rm -rf "${src}"
  if [[ "${extracted}" == "1" ]]; then rm -rf "${T2A_SRC_DIR}/uosa-install"; fi
  if [[ "${code}" == "0" ]]; then ok "Intact Magincia added to the modern map."
  else warn "The Magincia paste did not run (close the game); run install.sh again."; fi
}

check_server_map() {
  local off="" f
  for f in ${MAP_FILES}; do
    [[ "$(sha256sum "${UO_DATA}/${f}" | cut -d' ' -f1)" == "${SERVER_MAP_SHA[${f}]}" ]] || off="${off} ${f}"
  done
  if [[ -z "${off}" ]]; then ok "Your map files match the UO Smallz server's."
  else warn "Your${off} differ from the server's: some places may look different in game (another UO data version?)."; fi
}

if [[ "${INSTALL_T2A_MAP}" == "1" ]]; then swap_t2a_map
else
  banner "Felucca map art (the server's: modern map, intact Magincia)"
  restore_modern_map; paste_magincia; check_server_map
fi

cat > "$ROOT/Client/settings.json" <<JSON
{
  "username": "", "password": "",
  "ip": "$HOST", "port": $PORT,
  "ultimaonlinedirectory": "$UO_DATA",
  "clientversion": "$VER",
  "lastservernum": 1, "last_server_name": "UO Smallz", "fps": 60,
  "encryption": 0, "saveaccount": false, "autologin": false, "plugins": []
}
JSON
ok "Wrote $ROOT/Client/settings.json"

# HD art: only for a client that draws it at the art's own size (patches/client/0003); an older one
# would draw every item twice as big. Every problem is a warning: the game runs without it.
install_hd_art() {
  banner "HD art"
  [[ "${INSTALL_HD_ART:-1}" == "1" ]] || { say "Skipped (INSTALL_HD_ART=0)."; return 0; }
  grep -aq ScaledTexture2D "$ROOT/Client/ClassicUO.Renderer.dll" 2>/dev/null || { warn "This client can't draw HD art yet; skipped."; return 0; }
  local m info file size sha have="" zip="$ROOT/hdart.zip"
  m="$(curl -fsSL -A "$UA" --max-time 20 "$HD_ART_MANIFEST" 2>/dev/null)" || { warn "hd-art.json not reachable; HD art skipped."; return 0; }
  info="$(printf '%s' "$m" | python3 -c 'import json,sys; j=json.load(sys.stdin); print(j["file"], int(j["size"]), str(j["sha256"]).lower())' 2>/dev/null)" || info=""
  read -r file size sha <<< "${info:-x 0 x}"
  if [[ ! "$file" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.zip$ || ! "$sha" =~ ^[0-9a-f]{64}$ || "$size" -le 0 ]]; then
    warn "hd-art.json is not valid; HD art skipped."; return 0
  fi
  [[ -f "$ROOT/hdart-version.json" ]] && have="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["sha256"])' "$ROOT/hdart-version.json" 2>/dev/null || true)"
  [[ "$have" == "$sha" ]] && { ok "HD art up to date."; return 0; }
  say "Downloading the HD art ($(( size / 1048576 )) MB from the UO Smallz server)..."
  # -C -: an earlier run that broke off carries on where it stopped
  curl -fL -C - --progress-bar -A "$UA" -o "$zip" "${HD_ART_BASE}${file}" || { warn "HD art download failed; run install.sh again to carry on."; return 0; }
  echo "$sha  $zip" | sha256sum -c --quiet - || { rm -f "$zip"; warn "The HD art download didn't match hd-art.json; deleted."; return 0; }
  rm -rf "$ROOT/HDArt.new" "$ROOT/HDArt.old"
  unzip -q "$zip" -d "$ROOT/HDArt.new" && [[ -d "$ROOT/HDArt.new/art" ]] || { rm -rf "$ROOT/HDArt.new"; warn "Could not unpack the HD art; the art you had stays."; return 0; }
  # the creatures stay
  [[ -d "$ROOT/HDArt/anim" && ! -e "$ROOT/HDArt.new/anim" ]] && mv "$ROOT/HDArt/anim" "$ROOT/HDArt.new/anim"
  [[ -d "$ROOT/HDArt" ]] && mv "$ROOT/HDArt" "$ROOT/HDArt.old"
  mv "$ROOT/HDArt.new" "$ROOT/HDArt"
  rm -rf "$ROOT/HDArt.old" "$zip"
  printf '{ "sha256": "%s" }\n' "$sha" > "$ROOT/hdart-version.json"
  ok "HD art: $ROOT/HDArt"
}
install_hd_art

# HD creatures: only for a client with the animation hook (HdAnimations). Each part is kept when it is
# already there and right, else fetched as .part (carrying on a broken one), checked, and moved in.
install_hd_creatures() {
  banner "HD creatures"
  [[ "${INSTALL_HD_CREATURES:-1}" == "1" ]] || { say "Skipped (INSTALL_HD_CREATURES=0)."; return 0; }
  grep -aq HdAnimations "$ROOT/Client/ClassicUO.Assets.dll" 2>/dev/null || { warn "This client can't draw HD creatures yet; skipped."; return 0; }
  local m list file size sha dir="$ROOT/HDArt/anim" total=0 n=0 i=0 keep=" "
  m="$(curl -fsSL -A "$UA" --max-time 20 "$HD_ART_MANIFEST" 2>/dev/null)" || { warn "hd-art.json not reachable; HD creatures skipped."; return 0; }
  list="$(printf '%s' "$m" | python3 -c 'import json,sys
for f in json.load(sys.stdin).get("creatures", {}).get("files", []): print(f["file"], int(f["size"]), str(f["sha256"]).lower())' 2>/dev/null)" || list=""
  [[ -n "$list" ]] || { say "No HD creatures listed yet."; return 0; }
  while read -r file size sha; do
    if [[ ! "$file" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.uoanim$ || ! "$sha" =~ ^[0-9a-f]{64}$ || "$size" -le 0 ]]; then
      warn "hd-art.json is not valid; HD creatures skipped."; return 0
    fi
    total=$(( total + size )); n=$(( n + 1 ))
  done <<< "$list"
  mkdir -p "$dir"
  say "$n parts, $(( total / 1048576 )) MB in all from the UO Smallz server."
  while read -r file size sha; do
    i=$(( i + 1 )); keep="$keep$file "
    if [[ -f "$dir/$file" && "$(stat -c %s "$dir/$file")" == "$size" ]] && echo "$sha  $dir/$file" | sha256sum -c --quiet - 2>/dev/null; then
      say "Part $i of $n: up to date."; continue
    fi
    say "Part $i of $n: $(( size / 1048576 )) MB..."
    curl -fL -C - --progress-bar -A "$UA" -o "$dir/$file.part" "${HD_ART_BASE}${file}" || { warn "HD creatures download failed; run install.sh again to carry on."; return 0; }
    echo "$sha  $dir/$file.part" | sha256sum -c --quiet - || { rm -f "$dir/$file.part"; warn "Part $i didn't match hd-art.json; deleted. Run install.sh again."; return 0; }
    mv -f "$dir/$file.part" "$dir/$file"
  done <<< "$list"
  # parts an older set had
  for f in "$dir"/*; do if [[ -f "$f" && "$keep" != *" $(basename "$f") "* ]]; then rm -f "$f"; fi; done
  ok "HD creatures: $dir"
}
install_hd_creatures
mkdir -p "$HOME/.local/share/applications"
cat > "$HOME/.local/share/applications/uosmallz.desktop" <<D
[Desktop Entry]
Type=Application
Name=UO Smallz
Exec="$ROOT/Client/TazUO"
Path=$ROOT/Client
Terminal=false
Categories=Game;
D
echo; echo "Done. Run: $ROOT/Client/TazUO  (or 'UO Smallz' in your app menu)."
echo "New player? Type any new username/password at login; the account is created automatically."
