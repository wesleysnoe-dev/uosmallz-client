#!/usr/bin/env bash
# UO Smallz player installer (Linux x64).
# Needs: curl, unzip, sha256sum, python3, 7z (p7zip, for the classic map) and
# one RAR5 extractor for the game data: unar, unrar or 7zz (p7zip cannot read RAR5).
set -euo pipefail
HOST=uosmallz.duckdns.org; PORT=2593; VER=7.0.23.1
CLIENT_URL=https://github.com/wesleysnoe-dev/uosmallz-client/releases/download/v1/UOSmallz-Client-linux-x64.zip
# Same mirror, file and hash as the UO Offline installer.
DATA_URL=https://mirror.ashkantra.de/fullclients/7.0.23.1.exe
DATA_SHA=23b0548252bb4e6f39afbddac2e64f8deb862fbfaccb1303b87895d295e01839
T2A_INSTALLER_URL="https://download.uosecondage.com/UOSA_Client_Setup.exe"
T2A_INSTALLER_SHA256="674ec3cce9621bd8c1a8f2f69070e64e63191ce73d6f297236bf8f3b89d41ddf"
INSTALL_T2A_MAP="${INSTALL_CLASSIC_MAP:-1}"
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
[ -f "$zip" ] || { zip="$ROOT/client.zip"; say "Downloading client..."; curl -fL -A "$UA" -o "$zip" "$CLIENT_URL"; }
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

# Classic Felucca map art (same steps as the UO Offline install.sh).
T2A_SRC_DIR="$ROOT/t2a-src"
swap_t2a_map() {
  banner "Installing classic Felucca map art (intact Magincia)"
  [[ "${INSTALL_T2A_MAP}" == "1" ]] || { say "INSTALL_CLASSIC_MAP off; keeping modern map art."; return; }
  local backup_dir="${UO_DATA}/_backup-modern-map"
  if [[ -f "${backup_dir}/map0.mul" ]]; then say "Classic map already swapped (modern backup exists). Skipping."; return; fi
  command -v 7z >/dev/null || { warn "7z not found; skipping the classic map swap (install p7zip and re-run)."; return; }
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
  local missing=0 f src; declare -A src_path
  for f in map0.mul statics0.mul staidx0.mul; do
    src="$(find "${extract_dir}" -maxdepth 4 -name "${f}" -print -quit 2>/dev/null || true)"
    if [[ -z "${src}" ]]; then warn "Classic ${f} not found after extract."; missing=1; else src_path[${f}]="${src}"; fi
  done
  [[ "${missing}" == "0" ]] || { warn "Aborting the classic map swap; modern map kept."; return; }
  mkdir -p "${backup_dir}"
  for f in map0.mul statics0.mul staidx0.mul radarcol.mul tiledata.mul; do
    [[ -f "${UO_DATA}/${f}" ]] && cp -f "${UO_DATA}/${f}" "${backup_dir}/${f}"
  done
  ok "Backed up modern map -> ${backup_dir}"
  for f in map0.mul statics0.mul staidx0.mul; do cp -f "${src_path[${f}]}" "${UO_DATA}/${f}"; done
  rm -rf "${extract_dir}"
  ok "Classic Felucca map art installed (intact Magincia)."
  # The 2002 areas (Solen hives, faction strongholds, Khaldun), as on the server.
  if command -v pwsh >/dev/null && [[ -f "$here/map-merge.ps1" ]]; then
    pwsh -NoProfile -File "$here/map-merge.ps1" -DataDir "${UO_DATA}" -NoPause && ok "2002 areas merged." || warn "map-merge.ps1 failed."
  else
    warn "PowerShell (pwsh) not found: the Solen hives / faction strongholds / Khaldun areas were not merged. Install pwsh and run: pwsh map-merge.ps1 -DataDir \"${UO_DATA}\" -NoPause"
  fi
}
swap_t2a_map

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
