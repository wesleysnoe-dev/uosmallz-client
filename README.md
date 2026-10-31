# UO Smallz - player client


Shard: uosmallz.duckdns.org port 2593 (Age of Shadows era, client 7.0.23.1)

WINDOWS (easy way)
  1. Download UOSmallz-Installer-win.zip and unzip it anywhere.
  2. Double-click install.bat. (Run straight from inside the zip, it first
     copies itself to %LOCALAPPDATA%\UOSmallz-installer and runs from there,
     because Windows can delete the zip's temporary folder mid-install.)
  3. Press Enter to accept the default folder (%LOCALAPPDATA%\UOSmallz).
     If you already have the UO Classic 7.0.23.1 files, type that folder;
     otherwise press Enter and the installer downloads them (~930 MB).
  4. Double-click "UO Smallz" on your desktop (or in the Start menu).

UPDATES (Windows)
  The UO Smallz shortcut checks for a newer client each time you start it
  (a few seconds at most; no internet = it just starts the game). When one
  is out you get Update Now / Play Now / Skip This Version. Updating keeps
  your settings.json and everything in Client\Data (characters' profiles,
  macros, window layout); the previous client stays in Client.old.
  Since v7 an update downloads only the files that changed (usually about
  10 MB instead of the whole 90 MB client), each one checked; if that is not
  possible it downloads the whole client as before. The launcher also keeps
  itself up to date, so you never need a new installer after installing.
  Running install.bat again is also safe: it keeps your settings.json.

WORLD MAP
  Since v8 the world map (World Map on the top bar) marks every
  town, bank, shop, healer, inn, stable, moongate, shrine, dungeon entrance
  and faction stronghold, each with its own icon; shops carry the name on
  their sign. Towns, moongates and dungeons show at every zoom, banks and
  inns from 1x, other shops from 1.5x, names from 2x or on hover. They live
  in MapMarkers and MapIcons beside TazUO.exe and come with client updates;
  your own markers (in Data\Client) are kept.

ITEM ICONS
  Since v9 the client carries a small (56x56) icon of every large item in
  ExternalImages\gumps (gump ids 0x8000-0xB6CA, made from the HD art by
  uo-offline-dev's tools/item-icons). The shard's gumps (auction house,
  veteran rewards, storage, stables, GM panel) show these instead of the full
  art when it would not fit its row. They come with client updates, beside
  TazUO.exe and outside Data\. item-icons.csv maps item id -> gump id.

CASTLE WINDOWS (v10)
  Since v10 the client carries the castle QoL kit's window art (gump ids
  0xB700-0xB76D in ExternalImages\gumps, above the item icons), art for the
  new castle items (item ids 0xFE00-0xFE0D in ExternalImages\art, 1x) and
  tiledata for them: patches/client/0005 reads TileData\*.csv beside
  TazUO.exe after the player's tiledata.mul (only ids 0xFE00-0xFE0D, since
  v17 also the shard-item block 0x4C00-0x4CFF; bad
  lines are logged as "TileData overrides: ..." and skipped). The player's
  UO files stay untouched; all of it comes with client updates.

CASTLE ART FIX (v11)
  v11 redraws the castle item art (0xFE00-0xFE0D) with stock tile anchoring
  and size, gives the castle books a stock book's tiledata (height 1, no
  container flag) and adds patches/client/0006: items whose art exists only
  as an ExternalImages PNG now take their click area from their own sprite,
  so the tomes and checkbook can be picked up again.

CASTLE ART, BANK DEPOSIT SAFE (v12)
  v12 redraws two item images, 0xFE06 and 0xFE07 in ExternalImages\art: the
  Bank Deposit Safe is now a gold iron chest, drawn like the stock chest in
  both facings so it can be turned. Nothing else changes; the tiledata rows
  for these ids are unchanged.

CASTLE ART, MAGIC ITEM VAULT (v13)
  v13 turns the Magic Item Vault into a Red Armoire with a crystal ball and
  hat: new item art for 0xFE04 and 0xFE05 (ExternalImages\art), a new vault
  header icon 0xB769 (ExternalImages\gumps) and updated TileData rows for
  the two item ids (light and height). Nothing else changes.

FACTION TABARDS (v14, item ids moved in v15)
  v14 added the four faction tabards: item art (1x, two facings per faction in
  ExternalImages\art), paperdoll gumps 0xC81E-0xC821 (male) and 0xEF2E-0xEF31
  (female) in ExternalImages\gumps, tiledata rows for the item ids
  (TileData\faction-tabards.csv) and EquipConv\faction-tabards.csv, read by
  patches/client/0007: it adds equipment conversions for the shard's tabard anim ids
  1230-1233 (bodies human and elf, male and female), so a worn tabard draws as the
  stock surcoat animation in the world (in the faction's colour) and as its own gump
  on the paperdoll. The player's Equipconv.def stays untouched. Bad lines are logged
  as "EquipConv overrides: ..." and skipped. Until the shard turns
  uooffline.factionTabards on, nothing shows these.
  v15 moves the item art from 0xFE10-0xFE17 to 0x4C00-0x4C07 (0xFE10 -> 0x4C00 ...
  0xFE17 -> 0x4C07): the server's 0x78 mobile packet masks a worn item's id with
  0x7FFF, so 0xFE10 arrived as 0x7E10 (no art) and a worn tabard vanished after a gate.
  0x4C00-0x4C07 are blank in the stock 7.0.23.1 art and tiledata and no static of the
  shard's maps uses them, and every packet a 7.0.23.1 client gets carries them unchanged
  (0x78 keeps ids below 0x8000; the ground, container and equip packets carry the full
  id). patches/client/0005's tiledata override accepts 0xFE00-0xFE0D (castle) and, since
  0007, 0x4C00-0x4C07 (tabards); since v17 (patch 0008) the whole shard-item block
  0x4C00-0x4CFF, and nothing between it and 0xFE00. Anim ids and gumps are unchanged.
  Server and client go together: the server moves existing tabards to the new ids at
  startup (uo-offline-dev ie-faction-tabards-migfix).

CORVAEOBORO ART: SCROLLS, REAGENTS, SPELL ICONS (v16, test)
  v16 swaps the look of 237 existing images for CorvaeOboro's CC0 art mods
  (https://github.com/CorvaeOboro/ultima_online_mods): the 64 Magery scrolls
  (item ids 0x1F2D-0x1F6C), 22 reagents (0x0F78-0x0F91) in ExternalImages\art, and
  151 spell icons of Magery, Necromancy, Chivalry, Bushido, Ninjitsu, Spellweaving
  and Mysticism (gump ids 0x08C0-0x08FF, 0x5000-0x5010, 0x5100-0x5109,
  0x5300-0x5327, 0x5400-0x5425, 0x59D8-0x59E7, 0x5DC0-0x5DCF) in
  ExternalImages\gumps. Same ids as the stock art, so the server and tiledata are
  untouched. Every PNG is exactly 2x the size of the stock image of its id (the mod's
  1x pixels, each doubled), so patch 0003 treats it as an HD version and draws it at the
  stock size: the same look with or without the HD art pack, and it wins over the
  pack's own image for that id. Clicking and the crop in vendor, grid, trade and loot
  windows follow the new picture (the PNG sampled down to the stock size; a PNG of any
  other size is a plain replacement, as before). Four stock reagent graphics (0x0F79,
  0x0F7C, 0x0F7F, 0x0F8B) have no Corvae art and stay stock. Credit: art by CorvaeOboro (CC0 1.0); the
  scrolls are based on ScrollsByJewele (Jewele) and ScrollsByCircle (Gaechti), and the
  Magery spell icons on MoreColorSpells (Gaechti and Boothby), per CorvaeOboro's own
  READMEs; CC0 covers CorvaeOboro's contribution only. Licence, credit and the id list
  are in ExternalImages\CORVAE-ART-NOTICE.txt and corvae-art-ids.csv, and in
  notices\NOTICE.txt. To go back, delete those PNGs (or install the previous client).

KNIGHT'S SURCOAT (client v17, new paperdoll art v18)
  v17 reserves the item id block 0x4C00-0x4CFF for the shard's own items:
  patches/client/0008 widens patch 0005's tiledata override from the tabards'
  0x4C00-0x4C07 to 0x4C00-0x4CFF (the tabards work as before; 0xFE00-0xFE0D is
  unchanged; nothing else is accepted). First item in the block: the Knight's
  Surcoat. Six new files: item art 0x4C08 and 0x4C09 (1x, two facings) in
  ExternalImages\art, paperdoll gumps 0xC81D (51229, male) and 0xEF2D (61229,
  female) in ExternalImages\gumps, TileData\knights-surcoat.csv (the stock
  surcoat's tiledata with anim id 1229) and EquipConv\knights-surcoat.csv (anim
  1229 -> the stock surcoat animation 910 in the world, gump 1229 on the
  paperdoll; 1229 is inside patch 0007's anim range, so 0007 is unchanged).
  An older client has no tiledata or art for these ids, so the surcoat is
  invisible there: the server item must only go out after players have v17.
  v18 replaces the two paperdoll gumps 0xC81D (51229) and 0xEF2D (61229) with
  Wes's hand-painted art; item art 0x4C08/0x4C09, anim 1229 and the csvs are
  unchanged.

HD ART
  Since client v4 the game can draw HD art: every item, gump and land tile
  at twice the detail, drawn at the normal size (the difference shows most
  when you zoom in). Since v5 hillsides are HD too, and small icons and
  button lettering are smoother. Since v6 creatures, people and what they
  wear are HD too (every frame of every animation).
  The launcher offers them once a client that draws them is installed: the
  art (~640 MB) and then the creatures (~4.7 GB, five files, so a broken
  download only redoes one), from this repo's GitHub release (hd-art-N, named
  in hd-art.json; a download that breaks off carries on next time), checked
  against hd-art.json (SHA-256), into an HDArt folder
  beside Client (creatures in HDArt\anim). Yes downloads now, No asks again
  next time, Cancel never asks for that pack again. Client updates don't
  touch them. To go back to the original art, delete the HDArt folder (or
  just HDArt\anim for the original creatures).
  Installed before v6? The client update arrives as usual, but the creatures
  offer comes from the new launcher: download the new UOSmallz-Installer-win.zip
  and run install.bat once more (it keeps your settings). From v6 on the
  launcher updates itself along with the client, so this is the last time.

LINUX
  Run install.sh from the installer zip. Needs curl, unzip, python3, p7zip,
  and unar (or unrar / 7zz). pwsh (PowerShell) is needed to paste intact
  Magincia onto the map; without it Magincia is bare ground.
  It installs the latest client, the HD art and the HD creatures
  (INSTALL_HD_ART=0 / INSTALL_HD_CREATURES=0 to skip); run it again to update.

LOGGING IN
  New player: type any new username and password at the login screen.
  The account is created the first time you log in. Remember them.

ABOUT THE GAME FILES
  Ultima Online game data is EA's and is not included here. The installer
  downloads the 7.0.23.1 client from a community mirror
  (mirror.ashkantra.de) and checks its SHA256 before using it. If you prefer,
  install UO Classic yourself and give the installer that folder; other
  client versions may show glitches, 7.0.23.1 is the tested one.

THE MAP
  Since October 22, 2026 the shard runs the modern Felucca map with the
  Magincia island pasted in from the classic map, so the town stands
  intact. The installer sets up exactly those map files and checks them
  against the server's ("Your map files match the UO Smallz server's").
  It pastes Magincia's land from your 7.0.23.1 data and its buildings from
  the UO Second Age client (~349 MB download from uosecondage.com, SHA256
  checked, only if your UO folder doesn't already have them).

  Installed before October 22? Your client still has the whole classic map,
  which no longer matches the server: places like the Minax stronghold show
  up black. Close the game, download the new UOSmallz-Installer-win.zip and
  run install.bat again. It puts the modern map back (the classic files go
  to _backup-classic-map-retired) and pastes Magincia. The game's own update
  check does not do this; it only updates the client program.

  INSTALL_CLASSIC_MAP=1 still installs the whole classic map, but it does not
  match the server.

MANUAL SETUP (no installer)
  Unzip UOSmallz-Client-win-x64.zip (or -linux-x64), then edit settings.json
  next to TazUO.exe: ip uosmallz.duckdns.org, port 2593,
  clientversion 7.0.23.1, encryption 0, ultimaonlinedirectory = your UO
  folder. A ready-made settings.json.example is included.

## License
  The client is TazUO (https://github.com/PlayTazUO/TazUO), a ClassicUO fork,
  BSD 2-Clause, with small UO Smallz changes (chat window, Groups button,
  HD art and creatures drawn at the art's own size, places on the world map).
  See the notices folder: license, notice, and the full change patch.
