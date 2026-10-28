#!/usr/bin/env bash
# v15 release-candidate check for the UO Smallz client repo. Read-only on the repo; writes only to --out.
#   tools/v15-rc-check.sh [--expect-version 15] [--base 3428c254] [--out DIR] [--release-dir DIR] [--strict]
#                         [--uo-data DIR] [--sa-statics DIR] [--corvae-table FILE]
# Paths (flag, else env var, else default; nothing is hard-coded to one machine):
#   --uo-data / UO_DATA            stock 7.0.23.1 folder (art/tiledata/statics/gumps); default <repo>/../uo-data/7.0.23.1.
#                                  Missing = the id and art checks that need stock data WARN and are skipped.
#   --sa-statics / SA_STATICS      folder with the shard's classic Felucca staidx0/statics0; default none = the modern map0
#                                  in UO_DATA is used instead (stricter, WARN).
#   --corvae-table / CORVAE_TABLE  a corvae id-table.json; only used when the tree has no ExternalImages/corvae-art-ids.csv.
#   --out                          output folder for SHA256SUMS; default <repo>/../v15-rc-out (outside the repo).
# Checks: 1 version, 2 installer/launcher/syntax, 3 ids and collisions, 3b Corvae art (v16+: every PNG exactly 2x the stock
# size, README/NOTICE credits, license files), 4 SHA256SUMS.
# Exit 0 = no FAIL, 1 = at least one FAIL. WARN/SKIP never fail unless --strict.
set -u
EXPECT=15; BASE=3428c254; OUT=""; RELDIR=""; STRICT=0; UO_DATA="${UO_DATA:-}"; SA_STATICS="${SA_STATICS:-}"; CORVAE_TABLE="${CORVAE_TABLE:-}"
while [ $# -gt 0 ]; do case "$1" in
  --expect-version) EXPECT="$2"; shift 2;; --base) BASE="$2"; shift 2;; --out) OUT="$2"; shift 2;;
  --release-dir) RELDIR="$2"; shift 2;; --strict) STRICT=1; shift;;
  --uo-data) UO_DATA="$2"; shift 2;; --sa-statics) SA_STATICS="$2"; shift 2;; --corvae-table) CORVAE_TABLE="$2"; shift 2;;
  -h|--help) sed -n 2,14p "$0"; exit 0;;
  *) echo "unknown arg $1"; exit 2;; esac; done
ROOT="$(git rev-parse --show-toplevel)"; cd "$ROOT" || exit 2
OUT="${OUT:-$ROOT/../v15-rc-out}"; mkdir -p "$OUT"
export UO_DATA="${UO_DATA:-$ROOT/../uo-data/7.0.23.1}" SA_STATICS="${SA_STATICS:-}" CORVAE_TABLE="${CORVAE_TABLE:-}" \
  V15_BASE="$BASE" V15_OUT="$OUT" V15_STRICT="$STRICT"
FAILS=0; WARNS=0
pass() { echo "PASS  $*"; }; fail() { echo "FAIL  $*"; FAILS=$((FAILS+1)); }
warn() { echo "WARN  $*"; WARNS=$((WARNS+1)); }; skip() { echo "SKIP  $*"; }
echo "== v15 rc check: $(git rev-parse --short HEAD) on $(git rev-parse --abbrev-ref HEAD), base $BASE, $(date '+%F %T %Z')"

echo "-- 1. version"
V="$(tr -d '[:space:]' < CLIENT_VERSION)"
[ "$V" = "$EXPECT" ] && pass "CLIENT_VERSION is $V" || fail "CLIENT_VERSION is '$V', expected $EXPECT"
if git tag -l "v$V" | grep -q .; then fail "local tag v$V already exists (the workflow refuses an existing tag)"; else pass "no local tag v$V"; fi
if RT="$(timeout 20 git ls-remote --tags origin "refs/tags/v$V" 2>/dev/null)"; then
  [ -z "$RT" ] && pass "origin has no tag v$V" || fail "origin already has tag v$V"; else skip "origin tags not reachable"; fi

echo "-- 2. installer and launcher"
LV() { sed -n 's/^\$LauncherVersion *= *\([0-9.]*\).*/\1/p' | head -1; }
LV_NOW="$(LV < installer/update-check.ps1)"; LV_BASE="$(git show "$BASE:installer/update-check.ps1" | LV)"
if git diff --quiet "$BASE" -- installer/update-check.ps1 installer/launch.vbs; then
  [ "$LV_NOW" = "$LV_BASE" ] && pass "launcher files unchanged vs $BASE, LauncherVersion stays $LV_NOW" || warn "launcher files unchanged but LauncherVersion $LV_BASE -> $LV_NOW"
else
  [ "$LV_NOW" != "$LV_BASE" ] && pass "launcher changed and LauncherVersion $LV_BASE -> $LV_NOW" || fail "launcher files changed vs $BASE but LauncherVersion is still $LV_NOW (bump it)"
fi
for f in installer/*.ps1 tests/*.ps1; do [ -f "$f" ] || continue
  if command -v pwsh >/dev/null; then
    R="$(pwsh -NoProfile -Command "\$e=\$null;\$t=\$null;[void][System.Management.Automation.Language.Parser]::ParseFile('$ROOT/$f',[ref]\$t,[ref]\$e);if(\$e.Count){\$e|%{ \"\$(\$_.Extent.StartLineNumber): \$(\$_.Message)\" };exit 1}" 2>&1)" \
      && pass "parse $f" || fail "parse $f: $(echo "$R" | head -3 | tr '\n' ' ')"
  else skip "parse $f (no pwsh)"; fi; done
for f in installer/*.sh tools/*.sh; do [ -f "$f" ] && { bash -n "$f" 2>/dev/null && pass "bash -n $f" || fail "bash -n $f"; }; done
python3 - <<'PY' && true || FAILS=$((FAILS+1))
import json, sys, glob
bad = 0
try:
    import yaml
    for f in glob.glob('.github/workflows/*.yml'):
        try: yaml.safe_load(open(f)); print('PASS  yaml', f)
        except Exception as e: print('FAIL  yaml', f, e); bad += 1
except ImportError: print('SKIP  yaml (no PyYAML)')
for f in ['hd-art.json', 'installer/settings.json.example']:
    try: json.load(open(f)); print('PASS  json', f)
    except Exception as e: print('FAIL  json', f, e); bad += 1
sys.exit(1 if bad else 0)
PY

echo "-- 3. ids: tiledata overrides, ExternalImages, collisions, corvae"
python3 - <<'PY'
import os, re, sys, csv, json, glob, struct
BASE = os.environ['V15_BASE']; UO = os.environ['UO_DATA']; SA = os.environ['SA_STATICS']
fails = warns = 0
def P(t, m):
    global fails, warns
    print(f'{t:<5} {m}')
    if t == 'FAIL': fails += 1
    if t == 'WARN': warns += 1
hx = lambda n: f'0x{n:04X}'
pid = lambda s: int(s.strip(), 16) if s.strip().lower().startswith('0x') else int(s.strip())
stem = lambda f: pid(os.path.splitext(os.path.basename(f))[0])
EI = 'client-files/ExternalImages'
art_ids = {stem(f): f for f in glob.glob(f'{EI}/art/*.png')}
gump_ids = {stem(f): f for f in glob.glob(f'{EI}/gumps/*.png')}
# --- tiledata csvs
td = {}; dup = []
for f in sorted(glob.glob('client-files/TileData/*.csv')):
    for n, l in enumerate(open(f, encoding='utf-8-sig'), 1):
        if not l.strip() or l.startswith('#'): continue
        c = l.rstrip('\n').split(',')
        if len(c) < 10: P('FAIL', f'{f}:{n} has {len(c)} fields (need 10)'); continue
        try: i = pid(c[0])
        except ValueError: P('FAIL', f'{f}:{n} bad id {c[0]!r}'); continue
        if i in td: dup.append((hx(i), td[i], os.path.basename(f)))
        td[i] = os.path.basename(f)
P('FAIL' if dup else 'PASS', f'{len(td)} tiledata override rows, duplicates: {dup or "none"}')
# --- override ranges the client patches accept (0005 + later widenings in the tabard patch)
rng = []
src = ''
for f in sorted(glob.glob('patches/client/*.patch')): src += open(f, errors='ignore').read()
# the final TileDataLoader.cs state: take every '+' / context line with  XFirst = 0x.., XLast = 0x..
for m in re.finditer(r'^[ +].*?\b(\w*First)\s*=\s*(0[xX][0-9A-Fa-f]+),\s*(\w*Last)\s*=\s*(0[xX][0-9A-Fa-f]+)', src, re.M):
    rng.append((m.group(1), int(m.group(2), 16), int(m.group(4), 16)))
# keep the last definition per name (a later patch edits an earlier line)
last = {}
for n, a, b in rng: last[n] = (a, b)
ranges = sorted(set(last.values()))
P('PASS' if ranges else 'FAIL', 'override ranges in patches: ' + ', '.join(f'{hx(a)}-{hx(b)}' for a, b in ranges))
inr = lambda i: any(a <= i <= b for a, b in ranges)
bad = [hx(i) for i in td if not inr(i)]
P('FAIL' if bad else 'PASS', f'tiledata ids outside every override range (client would skip them): {bad or "none"}')
unused = sorted(i for a, b in ranges for i in range(a, b + 1) if i not in td)
P('PASS', f'ids inside a range with no row (harmless): {len(unused)}')
miss = [hx(i) for i in td if i not in art_ids]
P('WARN' if miss else 'PASS', f'tiledata rows without an ExternalImages art PNG: {miss or "none"}')
# --- stock data
have_stock = os.path.exists(f'{UO}/artidx.mul') and os.path.exists(f'{UO}/tiledata.mul')
corvae = {'art': set(), 'gump': set()}
ct = os.path.join(EI, 'corvae-art-ids.csv')
if os.path.exists(ct):
    for r in csv.DictReader(open(ct)): corvae[r['kind']].add(pid(r['id']))
    csrc = ct
elif os.environ['CORVAE_TABLE'] and os.path.exists(os.environ['CORVAE_TABLE']):
    for r in json.load(open(os.environ['CORVAE_TABLE'])):
        if r['file']: corvae[r['kind']].add(r['dec'])
    csrc = os.environ['CORVAE_TABLE']
else: csrc = None
P('PASS' if csrc else 'WARN', f'corvae id list: {csrc or "not found"} ({len(corvae["art"])} art, {len(corvae["gump"])} gump)')
# ids this repo owns = everything in ExternalImages that is not corvae's (and not the v9 item icons, which are gump ids 0x8000-0xB6CA)
own_art = {i for i in art_ids if i not in corvae['art']} | set(td)
own_gump = {i for i in gump_ids if i not in corvae['gump']}
over_art = sorted(own_art & corvae['art']); over_gump = sorted(own_gump & corvae['gump'])
P('FAIL' if (over_art or over_gump) else 'PASS', f'collisions with corvae ids: art {[hx(i) for i in over_art] or "none"}, gump {[hx(i) for i in over_gump] or "none"}')
if csrc and csrc.endswith('.json'):
    # corvae not in this tree: still compare the incoming ids with everything the tree owns
    ov = sorted(({stem(f) for f in art_ids.values()} | set(td)) & corvae['art']); og = sorted(set(gump_ids) & corvae['gump'])
    P('FAIL' if (ov or og) else 'PASS', f'tree ids vs corvae-art-test table (it is not merged here): art {[hx(i) for i in ov] or "none"}, gump {[hx(i) for i in og] or "none"}')
# castle kit reserved
castle_art = set(range(0xFE00, 0xFE0E)); castle_gump = set(range(0xB700, 0xB800))
# --- art/tiledata ids vs stock, HD, statics
if not have_stock: P('WARN', f'stock data not found in {UO} (set --uo-data / UO_DATA): art/tiledata/statics checks skipped')
else:
    idx = open(f'{UO}/artidx.mul', 'rb').read(); tdd = open(f'{UO}/tiledata.mul', 'rb').read(); TDB = 512 * (4 + 32 * 30)
    def art_entry(i):
        o = (0x4000 + i) * 12
        if o + 12 > len(idx): return None
        lk, ln, _ = struct.unpack_from('<iii', idx, o)
        return None if lk < 0 or ln <= 0 else (lk, ln & 0x7FFFFFFF)
    def td_ent(i):
        if i >= 0x10000: return b'\0' * 41
        p = TDB + (i >> 5) * (4 + 32 * 41) + 4 + (i & 31) * 41; return tdd[p:p + 41]
    def stock_blank(i):
        e = art_entry(i); art_ok = (e is None) or e[1] <= 14   # absent, or the 14-byte 44x1 empty stub
        t = td_ent(i); td_ok = t[21:41].split(b'\0')[0] == b'' and struct.unpack_from('<q', t, 0)[0] == 0
        return art_ok, td_ok
    def statics(base, n):
        s = {}
        ixp = f'{base}/staidx{n}.mul'
        if not os.path.exists(ixp): return None
        ix = open(ixp, 'rb').read(); d = open(f'{base}/statics{n}.mul', 'rb')
        for b in range(len(ix) // 12):
            lk, ln, _ = struct.unpack_from('<iii', ix, b * 12)
            if lk < 0 or ln <= 0: continue
            d.seek(lk); buf = d.read(ln - ln % 7)
            for t in struct.iter_unpack('<HBBbH', buf): s[t[0]] = s.get(t[0], 0) + 1
        return s
    served = {}
    sa = SA if SA and os.path.exists(f'{SA}/statics0.mul') else UO
    if sa == UO: P('WARN', f'classic Felucca statics not found (SA_STATICS={SA or "unset"}); using the modern map0 in UO_DATA (stricter)')
    for lab, base, n in (('Felucca', sa, 0), ('Ilshenar', UO, 2), ('Malas', UO, 3)):
        s = statics(base, n)
        if s is None: P('WARN', f'no {lab} statics'); continue
        for k, v in s.items(): served.setdefault(k, {})[lab] = v
    ix = open(f'{UO}/multi.idx', 'rb').read(); d = open(f'{UO}/multi.mul', 'rb')
    for b in range(len(ix) // 12):
        lk, ln, _ = struct.unpack_from('<iii', ix, b * 12)
        if lk < 0 or ln <= 0: continue
        d.seek(lk); buf = d.read(ln); sz = 16 if ln % 16 == 0 else 12
        for k in range(0, ln - sz + 1, sz): served.setdefault(struct.unpack_from('<H', buf, k)[0], {})['multi'] = 1
    # new item ids = art PNGs and tiledata rows that are not a deliberate corvae replacement
    new_ids = sorted(own_art)
    bad = 0
    for i in new_ids:
        a_ok, t_ok = stock_blank(i); notes = []
        if not a_ok: notes.append('stock has real art here')
        if not t_ok and i not in td: notes.append('stock tiledata is not empty')
        elif not t_ok: notes.append('stock tiledata is not empty (override would replace a stock item)')
        if i in served: notes.append('static/multi use on ' + ', '.join(f'{k} x{v}' for k, v in served[i].items()))
        if notes and not (0xFE00 <= i <= 0xFE1F and not any('static' in n or 'stock' in n for n in notes)):
            P('FAIL', f'item id {hx(i)}: ' + '; '.join(notes)); bad += 1
    P('FAIL' if bad else 'PASS', f'{len(new_ids)} repo-owned item ids ({", ".join(hx(i) for i in new_ids[:3])}...) checked against stock art/tiledata/statics/multi: {bad} problem(s)')
    # item ids must also fit the packets: worn items are masked 0x7FFF for clients below 7.0.33.1; ground items 0xFFFF for HS clients
    big = [hx(i) for i in new_ids if i > 0x7FFF and i not in castle_art]
    P('WARN' if big else 'PASS', f'repo-owned item ids above 0x7FFF (a worn item is masked 0x7FFF for a 7.0.23.1 client): {big or "none"}')
    # corvae replacements must replace real stock art (a deliberate swap) and not clash with castle
    rep = sorted(i for i in art_ids if i in corvae['art'])
    P('PASS', f'{len(rep)} corvae item ids present in the tree; {sum(1 for i in rep if not stock_blank(i)[0])} replace real stock art')
    gstock = os.path.exists(f'{UO}/gumpidx.mul')
    if gstock:
        gx = open(f'{UO}/gumpidx.mul', 'rb').read()
        def gump_has(i):
            o = i * 12
            if o + 12 > len(gx): return False
            lk, ln, _ = struct.unpack_from('<iii', gx, o); return lk >= 0 and ln > 0
        repl = sorted(i for i in gump_ids if gump_has(i))
        unexp = [hx(i) for i in repl if i not in corvae['gump']]
        P('FAIL' if unexp else 'PASS', f'ExternalImages gumps that replace a stock gump and are not a corvae icon: {unexp[:12] or "none"}{" ... " + str(len(unexp)) if len(unexp) > 12 else ""}')
        P('PASS', f'{len(gump_ids) - len(repl)} gump ids are new (no stock gump), {len([i for i in repl if i in corvae["gump"]])} replace corvae spell icons')
    else: P('WARN', 'gumpidx.mul missing: gump replacement check skipped')
# --- overlaps among our own families (castle / tabards / icons) regardless of stock
fam = {'castle art': {i for i in art_ids if 0xFE00 <= i <= 0xFE0D}}
if sum(1 for i in castle_gump if i in gump_ids) == 0: P('WARN', 'no castle kit gumps 0xB700-0xB7FF in the tree')
EQ = set()
for f in glob.glob('client-files/EquipConv/*.csv'):
    for l in open(f):
        if l.strip() and not l.startswith(('#', 'body')):
            c = l.split(',')
            try: EQ.add(pid(c[1]))
            except Exception: pass
eqg = {50000 + a for a in EQ} | {60000 + a for a in EQ}
og = sorted(eqg & set(gump_ids))
P('PASS', f'EquipConv paperdoll gump ids ({len(eqg)}) all have art: {all(i in gump_ids for i in eqg)}; overlap with castle/corvae gumps: {sorted(set(hx(i) for i in eqg) & set(hx(i) for i in castle_gump | corvae["gump"])) or "none"}')
print(f'SUMMARY ids: {fails} fail, {warns} warn')
sys.exit(1 if fails else 0)
PY
[ $? -ne 0 ] && FAILS=$((FAILS+1))

echo "-- 3b. corvae art: PNG sizes, credits, license files"
python3 - <<'PY'
import os, re, sys, csv, struct
UO = os.environ['UO_DATA']
EI = 'client-files/ExternalImages'
ct = os.path.join(EI, 'corvae-art-ids.csv')
fails = warns = 0
def P(t, m):
    global fails, warns
    print(f'{t:<5} {m}')
    if t == 'FAIL': fails += 1
    if t == 'WARN': warns += 1
if not os.path.exists(ct):
    print('SKIP  no ExternalImages/corvae-art-ids.csv in this tree: no corvae art to check')
    sys.exit(0)
hx = lambda n: f'0x{n:04X}'
pid = lambda s: int(s.strip(), 16) if s.strip().lower().startswith('0x') else int(s.strip())
def png_size(p):
    with open(p, 'rb') as fh: h = fh.read(24)
    return struct.unpack('>II', h[16:24]) if h[:8] == b'\x89PNG\r\n\x1a\n' and h[12:16] == b'IHDR' else None
rows = list(csv.DictReader(open(ct, encoding='utf-8-sig')))
# stock sizes straight from the stock files, when present
art_idx = os.path.join(UO, 'artidx.mul'); gump_idx = os.path.join(UO, 'gumpidx.mul')
def stock_art(i):
    d = open(art_idx, 'rb').read(); o = (0x4000 + i) * 12
    if o + 12 > len(d): return None
    lk, ln, _ = struct.unpack_from('<iii', d, o)
    if lk < 0 or ln < 8: return None
    with open(os.path.join(UO, 'art.mul'), 'rb') as fh: fh.seek(lk); _, w, h = struct.unpack('<iHH', fh.read(8))
    return (w, h)
def stock_gump(i):
    d = open(gump_idx, 'rb').read(); o = i * 12
    if o + 12 > len(d): return None
    lk, ln, ex = struct.unpack_from('<iii', d, o)
    return None if lk < 0 or ln <= 0 else ((ex >> 16) & 0xFFFF, ex & 0xFFFF)
have_stock = all(os.path.exists(os.path.join(UO, n)) for n in ('artidx.mul', 'art.mul', 'gumpidx.mul'))
if not have_stock: P('WARN', f'stock art/gump files not in {UO} (set --uo-data / UO_DATA): PNG sizes are checked against the sizes recorded in corvae-art-ids.csv only')
missing = []; bad = []; checked = 0; vs_stock = 0
for r in rows:
    i = pid(r['id']); kind = r['kind']
    f = os.path.join(EI, 'art' if kind == 'art' else 'gumps', f'0x{i:04X}.png')
    if not os.path.exists(f): missing.append(f'{kind} {hx(i)}'); continue
    sz = png_size(f)
    if sz is None: bad.append(f'{kind} {hx(i)}: not a PNG'); continue
    checked += 1
    m = re.match(r'(\d+)x(\d+)$', r.get('stock_size', '').strip())
    st = (int(m.group(1)), int(m.group(2))) if m else None
    real = (stock_art if kind == 'art' else stock_gump)(i) if have_stock else None
    if real:
        vs_stock += 1
        if st and st != real: bad.append(f'{kind} {hx(i)}: csv stock_size {st} but the stock file says {real}')
        st = real
    if st is None: bad.append(f'{kind} {hx(i)}: no stock size to compare with')
    elif sz != (st[0] * 2, st[1] * 2): bad.append(f'{kind} {hx(i)}: PNG {sz[0]}x{sz[1]} is not exactly 2x stock {st[0]}x{st[1]}')
P('FAIL' if missing else 'PASS', f'every id in corvae-art-ids.csv has its PNG ({len(rows)} rows): missing {missing[:8] or "none"}')
P('FAIL' if bad else 'PASS', f'{checked} PNGs exactly 2x the stock size ({vs_stock} against the stock files, the rest against the csv): {bad[:8] or "no problems"}{" ... " + str(len(bad)) if len(bad) > 8 else ""}')
# credits and license files
for need in ('CORVAE-ART-LICENSE-CC0.txt', 'CORVAE-ART-NOTICE.txt'):
    P('PASS' if os.path.exists(os.path.join(EI, need)) else 'FAIL', f'{EI}/{need} present')
for doc in ('README.md', 'notices/NOTICE.txt'):
    t = open(doc, encoding='utf-8', errors='ignore').read() if os.path.exists(doc) else ''
    lack = [n for n in ('Jewele', 'Gaechti', 'Boothby', 'CorvaeOboro') if n not in t]
    P('FAIL' if lack else 'PASS', f'{doc} credits CorvaeOboro, Jewele, Gaechti, Boothby: missing {lack or "none"}')
print(f'SUMMARY art: {fails} fail, {warns} warn')
sys.exit(1 if fails else 0)
PY
[ $? -ne 0 ] && FAILS=$((FAILS+1))

echo "-- 4. SHA256SUMS -> $OUT"
( cd client-files && find . -type f | LC_ALL=C sort | sed 's|^\./||' | while read -r f; do sha256sum "$f"; done ) > "$OUT/SHA256SUMS-client-files.txt"
pass "client-files: $(wc -l < "$OUT/SHA256SUMS-client-files.txt") files -> SHA256SUMS-client-files.txt"
{ echo "# v15 rc $(git rev-parse HEAD) CLIENT_VERSION $V $(date -u +%FT%TZ)"
  sha256sum CLIENT_VERSION hd-art.json patches/client/*.patch notices/NOTICE.txt installer/update-check.ps1 installer/install.ps1 installer/install.sh
  if [ -n "$RELDIR" ] && ls "$RELDIR"/*.zip >/dev/null 2>&1; then ( cd "$RELDIR" && sha256sum *.zip *.files.json 2>/dev/null ); fi
} > "$OUT/SHA256SUMS.txt"
if [ -n "$RELDIR" ]; then ls "$RELDIR"/*.zip >/dev/null 2>&1 && pass "release zips hashed from $RELDIR" || warn "no release zips in $RELDIR"; else skip "no --release-dir: zips not hashed (build output not present yet)"; fi
pass "SHA256SUMS.txt written ($(grep -vc '^#' "$OUT/SHA256SUMS.txt") entries)"

echo "== result: $FAILS fail, $WARNS warn (python section reports its own counts above)"
[ "$STRICT" = 1 ] && [ "$WARNS" -gt 0 ] && exit 1
[ "$FAILS" -gt 0 ] && exit 1 || exit 0
