# UO Smallz - player client


Shard: uosmallz.duckdns.org port 2593 (Age of Shadows era, client 7.0.23.1)

WINDOWS (easy way)
  1. Download UOSmallz-Installer-win.zip and unzip it anywhere.
  2. Double-click install.bat.
  3. Press Enter to accept the default folder (%LOCALAPPDATA%\UOSmallz).
     If you already have the UO Classic 7.0.23.1 files, type that folder;
     otherwise press Enter and the installer downloads them (~930 MB).
  4. Double-click "UO Smallz" on your desktop.

LINUX
  Run install.sh from the installer zip. Needs curl, unzip, python3, p7zip,
  and unar (or unrar / 7zz). pwsh is optional (for the 2002 map areas).

LOGGING IN
  New player: type any new username and password at the login screen.
  The account is created the first time you log in. Remember them.

ABOUT THE GAME FILES
  Ultima Online game data is EA's and is not included here. The installer
  downloads the 7.0.23.1 client from a community mirror
  (mirror.ashkantra.de) and checks its SHA256 before using it. If you prefer,
  install UO Classic yourself and give the installer that folder; other
  client versions may show glitches, 7.0.23.1 is the tested one.

CLASSIC MAP
  The shard uses the classic Felucca map (intact Magincia). The installer
  downloads the UO Second Age client (~349 MB, uosecondage.com, SHA256
  checked), copies its map0/statics0/staidx0.mul into your UO folder (the
  originals go to _backup-modern-map), then map-merge.ps1 adds the 2002
  areas (Solen hives, faction strongholds, Khaldun). Without this your map
  will not match the server. Skip it: set INSTALL_CLASSIC_MAP=0.

MANUAL SETUP (no installer)
  Unzip UOSmallz-Client-win-x64.zip (or -linux-x64), then edit settings.json
  next to TazUO.exe: ip uosmallz.duckdns.org, port 2593,
  clientversion 7.0.23.1, encryption 0, ultimaonlinedirectory = your UO
  folder. A ready-made settings.json.example is included.

## License
  The client is TazUO (https://github.com/PlayTazUO/TazUO), a ClassicUO fork,
  BSD 2-Clause, with small UO Smallz changes (chat window, Groups button).
  See the notices folder: license, notice, and the full change patch.
