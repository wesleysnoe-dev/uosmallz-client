#!/usr/bin/env bash
# UO Smallz player installer (Linux x64). Needs: curl, unzip, sha256sum, 7z (p7zip).
set -euo pipefail
HOST=uosmallz.duckdns.org; PORT=2593; VER=7.0.23.1
CLIENT_URL=https://github.com/wesleysnoe-dev/uosmallz-client/releases/download/v1/UOSmallz-Client-linux-x64.zip
DATA_URL=https://mirror.ashkantra.de/fullclients/7.0.23.1.exe
DATA_SHA=23b0548252bb4e6f39afbddac2e64f8deb862fbfaccb1303b87895d295e01839
ROOT="${1:-$HOME/.local/share/uosmallz}"
UA="Mozilla/5.0 (X11; Linux x86_64)"
for c in curl unzip sha256sum 7z; do command -v $c >/dev/null || { echo "Please install $c (7z: p7zip-full)"; exit 1; }; done
mkdir -p "$ROOT/Client" "$ROOT/UOData"
here="$(cd "$(dirname "$0")" && pwd)"; zip="$here/UOSmallz-Client-linux-x64.zip"
[ -f "$zip" ] || { zip="$ROOT/client.zip"; echo "Downloading client..."; curl -fL -A "$UA" -o "$zip" "$CLIENT_URL"; }
unzip -qo "$zip" -d "$ROOT/Client"; chmod +x "$ROOT/Client/TazUO" 2>/dev/null || true
data="$(dirname "$(find "$ROOT/UOData" -name tiledata.mul | head -1)" 2>/dev/null || true)"
if [ -z "$data" ] || [ "$data" = "." ]; then
  sfx="$ROOT/UOData/$VER.exe"
  echo "Downloading UO $VER game data (~930 MB, community mirror; EA content)..."
  curl -fL -A "$UA" -o "$sfx" "$DATA_URL"
  echo "$DATA_SHA  $sfx" | sha256sum -c - || { rm -f "$sfx"; echo "Checksum mismatch, aborting."; exit 1; }
  7z x -y -o"$ROOT/UOData/$VER" "$sfx" >/dev/null; rm -f "$sfx"
  data="$(dirname "$(find "$ROOT/UOData" -name tiledata.mul | head -1)")"
fi
cat > "$ROOT/Client/settings.json" <<JSON
{
  "username": "", "password": "",
  "ip": "$HOST", "port": $PORT,
  "ultimaonlinedirectory": "$data",
  "clientversion": "$VER",
  "lastservernum": 1, "last_server_name": "UO Smallz", "fps": 60,
  "encryption": 0, "saveaccount": false, "autologin": false, "plugins": []
}
JSON
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
echo "Done. Run: $ROOT/Client/TazUO  (or 'UO Smallz' in your app menu)."
echo "New player? Type any new username/password at login; the account is created automatically."
