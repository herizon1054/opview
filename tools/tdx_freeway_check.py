#!/usr/bin/env python3
"""
TDX 國道擴充測試（回堵長度 / 車速驟降 / 前方各車道車速）

用真實的 TDX 國道資料跑 opview 的判斷邏輯，確認結果合不合理。
計算邏輯逐行移植自 lib/services/tdx/tdx_traffic_core.dart（tdxQueueAhead、TdxSections.path、
TdxVdIndex.ahead、_lanesAhead）與 lib/selfdrive/ui/ui_state.dart（tdxQueueText、tdxDropText），
常數相同；Dart 那邊改了，這裡要跟著改。只用 Python 標準函式庫（3.9 以上）。

用法（Windows 例：py tools\\tdx_freeway_check.py ...）：
  金鑰：直接填在下面的 CLIENT_ID / CLIENT_SECRET（同 opview 顯示設定裡的金鑰）；
        也可以用 --id / --secret 或環境變數 TDX_CLIENT_ID / TDX_CLIENT_SECRET 覆蓋

  selftest                       離線自我測試（不需要金鑰）
  scan   [--kph 100] [--road 國道1號] [--save DIR | --load DIR]
                                 把全國道每個路段當成「車子在這段起點」各算一次，列出現在所有回堵、
                                 會觸發車速驟降的位置，並檢查結果有沒有矛盾
  point  --lat 25.05 --lon 121.6 --heading 180 [--kph 100] [--save DIR | --load DIR]
                                 單點：印出 opview 在這個位置 / 方向會顯示的內容（含車道車速）
  vdtest --lat … --lon … --heading …
                                 測 TDX 接不接受 Live VD 的 $filter，並印出前方偵測器的原始車道（LaneID / LaneType）

  --save DIR：把抓到的原始 JSON 存起來（可傳給我分析）；--load DIR：用存好的資料重跑，不連 TDX。
  靜態資料（路段線形、名稱、偵測器位置）會快取在 ~/.tdx_freeway_cache，7 天內不重抓。
"""
import argparse, gzip, json, math, os, re, ssl, sys, time, urllib.error, urllib.parse, urllib.request

# ================================================================== TDX 金鑰：直接填在這裡
# 到 TDX 會員中心「資料服務 → API 金鑰」複製；填了就不用每次帶 --id / --secret。
# 注意：填了金鑰的這個檔案不要傳給別人或上傳到 GitHub（包含要傳給我分析時，請只傳 --save 的資料夾）。
CLIENT_ID = ''
CLIENT_SECRET = ''
# ==================================================================
from datetime import datetime

# ------------------------------------------------------------------ 常數（同 tdx_traffic_core.dart）
ON_SECTION_M = 30.0
HEADING_DEG = 45.0
CHAIN_M = 120.0
CHAIN_DEG = 60.0
END_HEADING_M = 50.0
PATH_M = 5000.0
GRID = 500.0
BRIDGE_NEAR_M = 300.0   # 國道跨缺口（同 tdx_traffic_core.dart tdxBridgeNearM）
BRIDGE_FAR_M = 3000.0
BRIDGE_DEG = 20.0
OVERLAP_M = 2000.0      # 線形畫過頭（同 tdxOverlapM）
BRIDGE_LAT_M = 40.0
LIVE_MAX_AGE = 15 * 60.0
CONGESTION_KPH = {'Freeway': (80, 40)}

QUEUE_KPH = 40
QUEUE_START_M = 3000.0
DROP_AHEAD_M = 2000.0
DROP_DELTA_KPH = 40
VD_PATH_M = 40.0
VD_MIN_M = 150.0
VD_MAX_M = 3000.0
VD_CANDIDATES = 8
COMPASS = {'N': 0.0, 'NE': 45.0, 'E': 90.0, 'SE': 135.0, 'S': 180.0, 'SW': 225.0, 'W': 270.0, 'NW': 315.0}

KX = 111320.0 * math.cos(23.7 * math.pi / 180)
KY = 110540.0


def xy(lat, lon):
    return lon * KX, lat * KY


def ang_diff(a, b):
    return abs((a - b + 180.0) % 360.0 - 180.0)


def heading_of(dx, dy):
    return math.degrees(math.atan2(dx, dy)) % 360.0


_NUM = re.compile(r'(-?\d+(?:\.\d+)?)\s+(-?\d+(?:\.\d+)?)')


def wkt_points(s):
    return [(float(a), float(b)) for a, b in _NUM.findall(s or '')]


def thin(pts, step):
    if len(pts) < 3:
        return pts
    out = [pts[0]]
    for p in pts[1:-1]:
        if math.hypot(p[0] - out[-1][0], p[1] - out[-1][1]) >= step:
            out.append(p)
    out.append(pts[-1])
    return out


def parse_time(s):
    if not isinstance(s, str):
        return None
    try:
        return datetime.fromisoformat(s.replace('Z', '+00:00')).timestamp()
    except ValueError:
        return None


def items(j):
    if isinstance(j, list):
        return j
    if isinstance(j, dict):
        for v in j.values():
            if isinstance(v, list):
                return v
    return []


def dist_text(d):
    return f'{round(d / 50) * 50}公尺' if d < 950 else f'{d / 1000:.1f}公里'


def congestion_of(kph):
    if kph <= 0:
        return 'unknown'
    smooth, slow = CONGESTION_KPH['Freeway']
    return 'smooth' if kph >= smooth else 'slow' if kph >= slow else 'congested'


# ------------------------------------------------------------------ 靜態資料縮減
def shrink_shapes(j):
    out = {}
    for s in items(j):
        if not isinstance(s, dict):
            continue
        sid, geom = s.get('SectionID'), s.get('Geometry')
        if not isinstance(sid, str) or not sid or not isinstance(geom, str) or not geom:
            continue
        out[sid] = [[round(la, 6), round(lo, 6)] for lo, la in thin(wkt_points(geom), 0.0001)]
    return out


def shrink_sections(j):
    out = {}
    for s in items(j):
        if not isinstance(s, dict) or not isinstance(s.get('SectionID'), str):
            continue
        road = s.get('RoadName') if isinstance(s.get('RoadName'), str) else ''
        name = s.get('SectionName') if isinstance(s.get('SectionName'), str) and s.get('SectionName') else road
        out[s['SectionID']] = {'name': name, 'road': road}
    return out


def shrink_vds(j):
    out = {}
    for v in items(j):
        if not isinstance(v, dict):
            continue
        vid, la, lo = v.get('VDID'), v.get('PositionLat'), v.get('PositionLon')
        if not isinstance(vid, str) or not vid or not isinstance(la, (int, float)) or not isinstance(lo, (int, float)):
            continue
        links = v.get('DetectionLinks')
        first = links[0] if isinstance(links, list) and links and isinstance(links[0], dict) else {}
        out[vid] = [round(la, 6), round(lo, 6), COMPASS.get(first.get('Bearing'))]
    return out


# ------------------------------------------------------------------ 即時資料
def live_speeds(j, now):
    out = {}
    for s in items(j):
        if not isinstance(s, dict):
            continue
        t = parse_time(s.get('DataCollectTime'))
        if t is not None and now - t > LIVE_MAX_AGE:
            continue
        sp, sid = s.get('TravelSpeed'), s.get('SectionID')
        if isinstance(sid, str) and isinstance(sp, (int, float)) and math.isfinite(sp) and sp > 0:
            out[sid] = int(sp)
    return out


def live_vds(j, now):
    out = {}
    for v in items(j):
        if not isinstance(v, dict) or not isinstance(v.get('VDID'), str):
            continue
        if v.get('Status') != 0:
            continue
        t = parse_time(v.get('DataCollectTime'))
        if t is not None and now - t > LIVE_MAX_AGE:
            continue
        lanes = []
        flows = v.get('LinkFlows')
        for lf in flows if isinstance(flows, list) else []:
            ls = lf.get('Lanes') if isinstance(lf, dict) else None
            for ln in ls if isinstance(ls, list) else []:
                if not isinstance(ln, dict):
                    continue
                sp = ln.get('Speed')
                if not isinstance(sp, (int, float)) or not math.isfinite(sp) or sp <= 0:
                    continue
                lid, ty = ln.get('LaneID'), ln.get('LaneType')
                lanes.append({'id': int(lid) if isinstance(lid, (int, float)) else 0,
                              'type': int(ty) if isinstance(ty, (int, float)) else 0,
                              'speed': int(round(sp))})  # Dart: sp.round()（.5 遠離 0，Python 為銀行家捨入，差異可忽略）
        if not lanes:
            continue
        lanes.sort(key=lambda l: l['id'])
        out[v['VDID']] = lanes
    return out


# ------------------------------------------------------------------ 路段幾何（TdxSections）
def _fl(v):
    return math.floor(v / GRID)


class Sections:
    def __init__(self, shapes, names=None):
        self.pts, self.cum, self.grid, self.starts = {}, {}, {}, {}
        self.names = names or {}
        for sid, ll in shapes.items():
            p = [xy(q[0], q[1]) for q in ll if isinstance(q, list) and len(q) >= 2]
            if len(p) < 2:
                continue
            c = [0.0]
            for k in range(1, len(p)):
                c.append(c[-1] + math.hypot(p[k][0] - p[k - 1][0], p[k][1] - p[k - 1][1]))
            self.pts[sid], self.cum[sid] = p, c
            for i in range(len(p) - 1):
                for cell in self._cells(p[i], p[i + 1]):
                    self.grid.setdefault(cell, set()).add((sid, i))
            self.starts.setdefault((_fl(p[0][0]), _fl(p[0][1])), []).append(sid)

    def name_of(self, sid):
        return self.names.get(sid, {}).get('name', '')

    def road_of(self, sid):
        return self.names.get(sid, {}).get('road', '')

    @staticmethod
    def _cells(a, b):
        for i in range(_fl(min(a[0], b[0])), _fl(max(a[0], b[0])) + 1):
            for j in range(_fl(min(a[1], b[1])), _fl(max(a[1], b[1])) + 1):
                yield (i, j)

    def _near(self, x, y):
        i, j = _fl(x), _fl(y)
        out = set()
        for di in (-1, 0, 1):
            for dj in (-1, 0, 1):
                out |= self.grid.get((i + di, j + dj), set())
        return out

    def _seg_hit(self, sid, i, x, y):
        (ax, ay), (bx, by) = self.pts[sid][i], self.pts[sid][i + 1]
        dx, dy = bx - ax, by - ay
        ll = dx * dx + dy * dy
        t = 0.0 if ll == 0 else min(1.0, max(0.0, ((x - ax) * dx + (y - ay) * dy) / ll))
        px, py = ax + t * dx, ay + t * dy
        return math.hypot(x - px, y - py), self.cum[sid][i] + t * math.sqrt(ll), heading_of(dx, dy)

    def locate(self, x, y, hd):
        best = None
        for sid, i in self._near(x, y):
            d, s, h = self._seg_hit(sid, i, x, y)
            if d <= ON_SECTION_M and ang_diff(h, hd) <= HEADING_DEG and (best is None or d < best[0]):
                best = (d, sid, s)
        return None if best is None else (best[1], best[2])

    def end_heading(self, sid, start):
        p, c = self.pts[sid], self.cum[sid]
        if start:
            k = len(p) - 1
            for i in range(1, len(p)):
                if c[i] >= END_HEADING_M:
                    k = i
                    break
            a, b = p[0], p[k]
        else:
            k = 0
            for i in range(len(p) - 2, -1, -1):
                if c[-1] - c[i] >= END_HEADING_M:
                    k = i
                    break
            a, b = p[k], p[-1]
        return heading_of(b[0] - a[0], b[1] - a[1])

    def _next(self, sid, seen, bridge=True):
        """(下一段, 缺口公尺) 或 None。bridge：國道跨缺口規則（同 Dart TdxSections._next）"""
        ex, ey = self.pts[sid][-1]
        he = self.end_heading(sid, False)
        i, j = _fl(ex), _fl(ey)
        road = self.road_of(sid)
        if bridge and road:
            ux, uy = math.sin(math.radians(he)), math.cos(math.radians(he))
            p, c = self.pts[sid], self.cum[sid]
            length = c[-1]
            r = math.ceil(BRIDGE_FAR_M / GRID)
            near = None  # (下一段, 起點相對本段終點的位置：負 = 重疊、正 = 缺口)
            for di in range(-r, r + 1):
                for dj in range(-r, r + 1):
                    for s2 in self.starts.get((i + di, j + dj), []):
                        if s2 in seen or self.road_of(s2) != road:
                            continue
                        if ang_diff(self.end_heading(s2, True), he) > CHAIN_DEG:
                            continue
                        sx, sy = self.pts[s2][0]
                        qx, qy = self.pts[s2][-1]
                        if (qx - ex) * ux + (qy - ey) * uy <= 0:
                            continue
                        at = None
                        k = len(p) - 2
                        while k >= 0 and c[k + 1] >= length - OVERLAP_M:  # ① 起點落在本段線上（畫過頭）
                            d, a, _ = self._seg_hit(sid, k, sx, sy)
                            if d <= BRIDGE_LAT_M and a >= length - OVERLAP_M:
                                at = a - length
                                break
                            k -= 1
                        if at is None:  # ② 終點附近或正前方的缺口
                            g = math.hypot(sx - ex, sy - ey)
                            if g > BRIDGE_FAR_M:
                                continue
                            if g > BRIDGE_NEAR_M and ang_diff(heading_of(sx - ex, sy - ey), he) > BRIDGE_DEG:
                                continue
                            at = -g if (sx - ex) * ux + (sy - ey) * uy < 0 else g
                        if near is None or at < near[1]:
                            near = (s2, at)
            if near is not None:
                return near[0], (near[1] if abs(near[1]) > CHAIN_M else 0.0)
        best = None
        for di in (-1, 0, 1):
            for dj in (-1, 0, 1):
                for s2 in self.starts.get((i + di, j + dj), []):
                    if s2 in seen:
                        continue
                    sx, sy = self.pts[s2][0]
                    if math.hypot(sx - ex, sy - ey) > CHAIN_M:
                        continue
                    turn = ang_diff(self.end_heading(s2, True), he)
                    if turn > CHAIN_DEG:
                        continue
                    key = (1 if self.road_of(s2) != road else 0, turn)
                    if best is None or key < best[0]:
                        best = (key, s2)
        return None if best is None else (best[1], 0.0)

    def path(self, sid, along, bridge=True):
        c, p = self.cum[sid], self.pts[sid]
        secs = [{'sid': sid, 'd0': -along, 'd1': c[-1] - along}]
        line = []
        for k in range(len(p)):
            if c[k] < along:
                continue
            if k > 0 and c[k] > along and c[k] > c[k - 1]:
                t = (along - c[k - 1]) / (c[k] - c[k - 1])
                line.append((p[k - 1][0] + t * (p[k][0] - p[k - 1][0]), p[k - 1][1] + t * (p[k][1] - p[k - 1][1]), 0.0))
            for m in range(k, len(p)):
                line.append((p[m][0], p[m][1], c[m] - along))
            break
        off = c[-1] - along
        seen = {sid}
        cur = sid
        while off < PATH_M:
            hop = self._next(cur, seen, bridge)
            if hop is None:
                break
            nxt, gap = hop
            off += gap  # 跨缺口：距離加上缺口長度
            seen.add(nxt)
            cn, pn = self.cum[nxt], self.pts[nxt]
            secs.append({'sid': nxt, 'd0': off, 'd1': off + cn[-1]})
            for k in range(len(pn)):
                line.append((pn[k][0], pn[k][1], off + cn[k]))
            off += cn[-1]
            cur = nxt
        return secs, line


def on_path(line, x, y, max_d):
    best = None
    for k in range(len(line) - 1):
        ax, ay, sa = line[k]
        bx, by, sb = line[k + 1]
        dx, dy = bx - ax, by - ay
        ll = dx * dx + dy * dy
        t = 0.0 if ll == 0 else min(1.0, max(0.0, ((x - ax) * dx + (y - ay) * dy) / ll))
        d = math.hypot(x - ax - t * dx, y - ay - t * dy)
        if d <= max_d and (best is None or d < best[0]):
            best = (d, sa + t * (sb - sa))
    return None if best is None else best[1]


# ------------------------------------------------------------------ 國道擴充（tdxQueueAhead / TdxVdIndex / _lanesAhead）
def queue_ahead(secs, speeds):
    i = 0
    while i < len(secs):
        v = speeds.get(secs[i]['sid'])
        if max(0.0, secs[i]['d0']) > QUEUE_START_M:
            return None
        if v is not None and v < QUEUE_KPH:
            break
        i += 1
    if i >= len(secs):
        return None
    start = max(0.0, secs[i]['d0'])
    length, wsum, min_v, opened = 0.0, 0.0, 999, True
    used = []  # 回堵涵蓋的路段（測試用，Dart 沒有）
    reach = start  # 線形重疊時不重複算長度
    for k in range(i, len(secs)):
        v = speeds.get(secs[k]['sid'])
        if v is None or v >= QUEUE_KPH:
            opened = False
            break
        used.append(secs[k]['sid'])
        l = secs[k]['d1'] - max(reach, secs[k]['d0'])
        reach = max(reach, secs[k]['d1'])
        if l <= 0:
            continue
        length += l
        wsum += v * l
        min_v = min(min_v, v)
    if length <= 0:
        return None
    return {'d': start, 'len': length, 'avg': int(wsum / length + 0.5), 'min': min_v, 'open': opened, 'secs': used}


class VdIndex:
    def __init__(self, raw):
        self.all = []
        for k, v in raw.items():
            if not isinstance(v, list) or len(v) < 2:
                continue
            x, y = xy(v[0], v[1])
            self.all.append((k, x, y, v[2] if len(v) > 2 else None))

    def ahead(self, line, x, y, hd):
        if len(line) < 2:
            return []
        out = []
        for vid, vx, vy, b in self.all:
            if abs(vx - x) > PATH_M + 200 or abs(vy - y) > PATH_M + 200:
                continue
            if b is not None and ang_diff(b, hd) > 90.0:
                continue
            d = on_path(line, vx, vy, VD_PATH_M)
            if d is not None and d > 0:
                out.append((vid, d))
        out.sort(key=lambda e: e[1])
        return out[:VD_CANDIDATES]


def lanes_ahead(vd_ahead, live):
    if live is None:
        return None
    for vid, d in vd_ahead:
        if d < VD_MIN_M or d > VD_MAX_M:
            continue
        lanes = live.get(vid)
        if lanes:
            return {'d': d, 'vd': vid, 'lanes': lanes}
    return None


# ------------------------------------------------------------------ 畫面文字（UIState，公制）
def queue_text(q):
    if q is None:
        return ''
    length = dist_text(q['len']) + ('以上' if q['open'] else '')
    avg = f"均速 {q['avg']}"
    return f'回堵中 還有 {length}｜{avg}' if q['d'] < 50 else f"回堵 {dist_text(q['d'])}起 {length}｜{avg}"


def drop_text(q, ego_kph):
    if q is None or q['d'] > DROP_AHEAD_M or ego_kph - q['min'] < DROP_DELTA_KPH:
        return ''
    if q['d'] < 50:
        return f"車速驟降 已進入回堵 降至{q['min']}km"
    return f"車速驟降 前方{dist_text(q['d'])} 降至{q['min']}km"


def lanes_text(l):
    if l is None:
        return ''
    return f"車道 {dist_text(l['d'])}  內 " + '｜'.join(str(x['speed']) for x in l['lanes']) + ' 外'


# ------------------------------------------------------------------ TDX 連線
HOST = 'https://tdx.transportdata.tw'


def _ssl_context():
    """一般的憑證驗證（驗證伺服器憑證與主機名稱），但關掉 Python 3.13 起預設開啟的 VERIFY_X509_STRICT：
    TDX 憑證鏈中有憑證缺少 Subject Key Identifier，嚴格模式會回
    「certificate verify failed: Missing Subject Key Identifier」。手機 / 瀏覽器 / 舊版 Python 都不做這項檢查。"""
    ctx = ssl.create_default_context()
    if hasattr(ssl, 'VERIFY_X509_STRICT'):
        ctx.verify_flags &= ~ssl.VERIFY_X509_STRICT
    return ctx


_SSL = _ssl_context()
UA = 'Mozilla/5.0 (Linux; Android) opview tdx_traffic'
CACHE = os.path.join(os.path.expanduser('~'), '.tdx_freeway_cache')
STATIC_MAX_AGE = 7 * 86400


class Tdx:
    def __init__(self, cid, secret, save=None, load=None):
        self.cid, self.secret, self.save, self.load = cid, secret, save, load
        self.token = None
        self.calls = 0

    def _token(self):
        if self.token:
            return self.token
        if not self.cid or not self.secret:
            sys.exit('需要 TDX 金鑰：填在程式開頭的 CLIENT_ID / CLIENT_SECRET，'
                     '或用 --id / --secret、環境變數 TDX_CLIENT_ID / TDX_CLIENT_SECRET')
        body = urllib.parse.urlencode({'grant_type': 'client_credentials', 'client_id': self.cid.strip(),
                                       'client_secret': self.secret.strip()}).encode()
        req = urllib.request.Request(HOST + '/auth/realms/TDXConnect/protocol/openid-connect/token', data=body,
                                     headers={'User-Agent': UA, 'Content-Type': 'application/x-www-form-urlencoded'})
        try:
            with urllib.request.urlopen(req, timeout=20, context=_SSL) as r:
                self.token = json.loads(r.read())['access_token']
        except urllib.error.HTTPError as e:
            sys.exit(f'TDX 金鑰驗證失敗（HTTP {e.code}）：請確認 CLIENT_ID / CLIENT_SECRET 有沒有貼錯、前後多空白')
        except urllib.error.URLError as e:
            sys.exit(f'連不到 TDX：{e.reason}')
        return self.token

    def get(self, path, query=None, name=None):
        """回傳 (HTTP 狀態, JSON 或 None, 位元組數)"""
        if self.load:
            f = os.path.join(self.load, f'{name}.json')
            if not os.path.exists(f):
                return 404, None, 0
            with open(f, encoding='utf-8') as fp:
                raw = fp.read()
            return 200, json.loads(raw), len(raw)
        q = dict(query or {})
        q['$format'] = 'JSON'
        url = f'{HOST}/api/basic/{path}?' + urllib.parse.urlencode(q)
        req = urllib.request.Request(url, headers={'Authorization': f'Bearer {self._token()}', 'User-Agent': UA,
                                                   'Accept-Encoding': 'gzip'})
        self.calls += 1
        try:
            with urllib.request.urlopen(req, timeout=60, context=_SSL) as r:
                b = r.read()
                n = len(b)
                if r.headers.get('Content-Encoding') == 'gzip':
                    b = gzip.decompress(b)
                j = json.loads(b)
        except urllib.error.HTTPError as e:
            return e.code, None, 0
        except urllib.error.URLError as e:
            sys.exit(f'連不到 TDX（{path}）：{e.reason}')
        if self.save and name:
            os.makedirs(self.save, exist_ok=True)
            with open(os.path.join(self.save, f'{name}.json'), 'w', encoding='utf-8') as fp:
                json.dump(j, fp, ensure_ascii=False)
        return 200, j, n

    def static(self, path, name):
        """靜態資料：7 天快取（--load 時讀存好的檔）"""
        if self.load:
            return self.get(path, name=name)[1]
        os.makedirs(CACHE, exist_ok=True)
        f = os.path.join(CACHE, f'{name}.json')
        if os.path.exists(f) and time.time() - os.path.getmtime(f) < STATIC_MAX_AGE:
            with open(f, encoding='utf-8') as fp:
                j = json.load(fp)
        else:
            code, j, n = self.get(path, name=None)
            if code != 200:
                sys.exit(f'{path}：HTTP {code}')
            print(f'  下載 {path}：{n / 1024:.0f} KB（傳輸）')
            with open(f, 'w', encoding='utf-8') as fp:
                json.dump(j, fp, ensure_ascii=False)
        if self.save:
            os.makedirs(self.save, exist_ok=True)
            with open(os.path.join(self.save, f'{name}.json'), 'w', encoding='utf-8') as fp:
                json.dump(j, fp, ensure_ascii=False)
        return j


def load_freeway(tdx, with_vd=False):
    print('讀取國道靜態資料…')
    sections = Sections(shrink_shapes(tdx.static('v2/Road/Traffic/SectionShape/Freeway', 'shape_Freeway')),
                        shrink_sections(tdx.static('v2/Road/Traffic/Section/Freeway', 'sect_Freeway')))
    vds = VdIndex(shrink_vds(tdx.static('v2/Road/Traffic/VD/Freeway', 'vd_Freeway'))) if with_vd else None
    code, j, n = tdx.get('v2/Road/Traffic/Live/Freeway', name='live_Freeway')
    if code != 200:
        sys.exit(f'Live/Freeway：HTTP {code}')
    now = time.time()
    if tdx.load:  # 重跑存好的資料：以資料本身的收集時間為準，不然全部過期
        ts = [parse_time(s.get('DataCollectTime')) for s in items(j) if isinstance(s, dict)]
        ts = [t for t in ts if t]
        if ts:
            now = max(ts) + 60
    speeds = live_speeds(j, now)
    print(f'  路段 {len(sections.pts)}、有即時車速 {len(speeds)}' + (f'、偵測器 {len(vds.all)}' if vds else '')
          + (f'（資料時間 {datetime.fromtimestamp(now - 60):%m-%d %H:%M}）' if tdx.load else ''))
    return sections, speeds, vds, now


# ------------------------------------------------------------------ scan：全國道每段起點各算一次
SCAN_STEP_M = 250.0  # scan：每個路段每隔多少公尺模擬一次（opview 實際每秒算一次）


def cmd_scan(a, tdx):
    sections, speeds, _, _ = load_freeway(tdx)
    sids = sorted(s for s in sections.pts if not a.road or a.road in sections.road_of(s))
    problems = []
    queues = {}  # 回堵第一段 → 統計
    first_slow_checks = 0
    for sid in sids:
        length = sections.cum[sid][-1]
        along = 0.0
        while along < length or along == 0.0:
            secs, _ = sections.path(sid, along)
            q = queue_ahead(secs, speeds)
            # ---- 一致性檢查（不該發生的情況）
            if q is not None:
                if not (0 <= q['d'] <= QUEUE_START_M):
                    problems.append(f'{sid}@{along:.0f}：回堵起點 {q["d"]:.0f} m 超出 0–{QUEUE_START_M:.0f}')
                if q['min'] >= QUEUE_KPH or q['avg'] >= QUEUE_KPH or q['avg'] < q['min']:
                    problems.append(f'{sid}@{along:.0f}：車速不合理 min {q["min"]} avg {q["avg"]}')
                if q['len'] <= 0 or q['d'] + q['len'] > secs[-1]['d1'] + 1:
                    problems.append(f'{sid}@{along:.0f}：長度 {q["len"]:.0f} 超出路徑 {secs[-1]["d1"]:.0f}')
                for x in q['secs']:
                    if speeds.get(x, 999) >= QUEUE_KPH:
                        problems.append(f'{sid}@{along:.0f}：回堵段 {x} 車速 {speeds.get(x)} 不是 < {QUEUE_KPH}')
            first_slow = next((x for x in secs if speeds.get(x['sid'], 999) < QUEUE_KPH), None)
            if first_slow and max(0.0, first_slow['d0']) <= QUEUE_START_M:
                first_slow_checks += 1
                if q is None:
                    problems.append(f'{sid}@{along:.0f}：前方 {first_slow["d0"]:.0f} m 有 {speeds[first_slow["sid"]]} km/h 路段，卻沒有回堵')
            if q is not None and q['d'] >= 50:  # 從回堵外面看到的（在回堵裡面的不算新的一段）
                st = queues.setdefault(q['secs'][0], {'seen': 0.0, 'seen_from': None, 'drop': None, 'drop_from': None, 'q': q})
                if q['d'] > st['seen']:
                    st.update(seen=q['d'], seen_from=(sid, along), q=q)
                if drop_text(q, a.kph) and (st['drop'] is None or q['d'] > st['drop']):
                    st.update(drop=q['d'], drop_from=(sid, along))
            if along >= length:
                break
            along = min(length, along + SCAN_STEP_M)
    # 起點本身就在別段回堵裡的，併到前面那段（連續的慢路段算同一段）
    covered = {x for st in queues.values() for x in st['q']['secs'][1:]}
    for k in [k for k in queues if k in covered]:
        del queues[k]
    # 沒有從外面看到的慢路段：上游也是慢路段 → 同一段回堵的延續（超出前方 5 公里），不另列；
    # 完全沒有上游接到 → 列出來（國道起點，或 TDX 線形接不上）
    pred = {}
    for x in sections.pts:
        hop = sections._next(x, {x})
        if hop:
            pred.setdefault(hop[0], []).append(x)
    for sid in sids:
        v = speeds.get(sid)
        if v is None or v >= QUEUE_KPH or sid in covered or sid in queues:
            continue
        if any(speeds.get(u, 999) < QUEUE_KPH for u in pred.get(sid, [])):
            continue
        queues[sid] = {'seen': None, 'q': None, 'pred': pred.get(sid, [])}

    print(f'\n本車 {a.kph:.0f} km/h，每個路段每 {SCAN_STEP_M:.0f} m 模擬一次：共 {len(queues)} 段回堵（< {QUEUE_KPH} km/h）\n')
    for first, st in sorted(queues.items(), key=lambda kv: (sections.road_of(kv[0]), sections.name_of(kv[0]))):
        q = st['q']
        print(f'[{sections.road_of(first)}] {sections.name_of(first) or first}')
        if q is None:
            ps = st.get('pred') or []
            why = ('上游：' + '、'.join(sections.name_of(u) for u in ps)) if ps else '沒有任何路段接到這裡（國道起點，或 TDX 線形接不上）'
            print(f'    {speeds.get(first)} km/h；沒有從回堵外面報出（{why}）')
            continue
        sp = ' '.join(f'{speeds.get(x, "-")}' for x in q['secs'])
        names = ' → '.join(sections.name_of(x) for x in q['secs'])
        print(f'    回堵 {dist_text(q["len"])}{"以上" if q["open"] else ""}｜均速 {q["avg"]}（最慢 {q["min"]}）  各段 {sp} km/h')
        if len(q['secs']) > 1:
            print(f'    涵蓋：{names}')
        f_sid, f_al = st['seen_from']
        print(f'    最早在 {dist_text(st["seen"])} 前報出（從 {sections.name_of(f_sid)} 段內 {f_al:.0f} m）')
        if st['drop'] is not None:
            print(f'    車速驟降最早在 {dist_text(st["drop"])} 前觸發')
        else:
            print(f'    不觸發車速驟降（本車 {a.kph:.0f} 與最慢 {q["min"]} 差不到 {DROP_DELTA_KPH}）')

    # 現況：最慢的路段與車速分布（沒有回堵時也能確認資料是真的、有在變）
    pool = [(v, sid) for sid, v in speeds.items() if sid in sections.pts and (not a.road or a.road in sections.road_of(sid))]
    if pool:
        pool.sort()
        bins = [(0, 40), (40, 60), (60, 80), (80, 999)]
        dist = '、'.join(f'{lo}–{hi if hi < 999 else ""}：{sum(1 for v, _ in pool if lo <= v < hi)}' for lo, hi in bins)
        print(f'\n即時車速分布（km/h：路段數）{dist}')
        print('最慢 10 段：')
        for v, sid in pool[:10]:
            print(f'  {v:>3} km/h  {sections.road_of(sid)} {sections.name_of(sid)}  '
                  f'（{sections.cum[sid][-1] / 1000:.1f} 公里）')

    # 路段串接檢查（依道路名稱：「國道1號汐止五股高架道路」是高架；路段名稱裡的「高架汐止端」只是地名）
    elev, bridged, dead = [], [], 0
    for sid in sids:
        hop = sections._next(sid, {sid})
        if hop is None:
            dead += 1
            continue
        nxt, gap = hop
        if gap > 0:
            bridged.append((sid, nxt, gap))
        if ('高架' in sections.road_of(sid)) != ('高架' in sections.road_of(nxt)):
            ex, ey = sections.pts[sid][-1]
            sx, sy = sections.pts[nxt][0]
            elev.append((sid, nxt, math.hypot(sx - ex, sy - ey)))
    print(f'\n路段串接：{len(sids) - dead} 段接得到下一段、{dead} 段接不到（國道終點等）；'
          f'其中 {len(bridged)} 處跨過 TDX 線形缺口（> {CHAIN_M:.0f} m）')
    for sid, nxt, gap in sorted(bridged, key=lambda b: -b[2])[:10]:
        print(f'  缺口 {gap:5.0f} m  {sections.name_of(sid)}  →  {sections.name_of(nxt)}')
    print(f'高架 ↔ 平面 的串接：{len(elev)} 處（高架起訖點併回平面是正常的；高架中途接到平面就是接錯）')
    for sid, nxt, gap in elev[:30]:
        print(f'  {sections.name_of(sid)}  →  {sections.name_of(nxt)}（端點相距 {gap:.0f} m）')

    lens = sorted(sections.cum[s][-1] for s in sids)
    if lens:
        pct = lambda p: lens[min(len(lens) - 1, int(len(lens) * p))]
        print(f'\n路段長度：中位數 {pct(.5):.0f} m、p90 {pct(.9):.0f} m、最長 {lens[-1]:.0f} m'
              f'（回堵起點 / 長度的誤差最多約一個路段長）')
    short = sum(1 for sid in sids if sections.path(sid, 0.0)[0][-1]['d1'] < 3000)
    print(f'\n路徑接不到 3 公里的起點：{short} / {len(sids)}（國道終點、交流道匝道正常會有一些；比例很高代表路段串接有問題）')
    if problems:
        print(f'\n⚠ 發現 {len(problems)} 個矛盾：')
        for p in problems[:50]:
            print('  ' + p)
    else:
        print(f'\n✓ 沒有發現矛盾（{first_slow_checks} 個「前方 3 公里內有慢路段」的位置都正確報出回堵；起點、長度、車速檢查都通過）')
    print(f'\nTDX 呼叫 {tdx.calls} 次')


# ------------------------------------------------------------------ point：單點
def cmd_point(a, tdx):
    sections, speeds, vds, now = load_freeway(tdx, with_vd=True)
    x, y = xy(a.lat, a.lon)
    hit = sections.locate(x, y, a.heading)
    if hit is None:
        sys.exit(f'({a.lat}, {a.lon}) 方向 {a.heading}° 不在任何國道路段上（距離 ≤ {ON_SECTION_M:.0f} m、方向差 ≤ {HEADING_DEG:.0f}°）')
    sid, along = hit
    secs, line = sections.path(sid, along)
    print(f'\n位置：{sections.road_of(sid)} {sections.name_of(sid)}（{sid}，段內 {along:.0f} m）')
    print('前方路段：')
    for s in secs:
        v = speeds.get(s['sid'])
        print(f'  {max(0, s["d0"]):6.0f}–{s["d1"]:6.0f} m  {(str(v) if v is not None else "-"):>4} km/h  '
              f'{sections.name_of(s["sid"])}')
    q = queue_ahead(secs, speeds)
    print(f'\n回堵：{queue_text(q) or "（沒有）"}')
    print(f'車速驟降（本車 {a.kph:.0f}）：{drop_text(q, a.kph) or "（不觸發）"}')
    ahead = vds.ahead(line, x, y, a.heading)
    vd_live = None
    if ahead:
        vd_live, how = fetch_vd_live(tdx, [v for v, _ in ahead], now)
        print(f'\n前方偵測器（{how}）：')
        for vid, d in ahead:
            l = (vd_live or {}).get(vid)
            print(f'  {d:6.0f} m  {vid}  ' + (' '.join(f"L{x['id']}/T{x['type']}:{x['speed']}" for x in l) if l else '（無即時資料）'))
    print(f'車道車速：{lanes_text(lanes_ahead(ahead, vd_live)) or "（沒有）"}')
    print(f'\nTDX 呼叫 {tdx.calls} 次')


def fetch_vd_live(tdx, ids, now):
    flt = ' or '.join("VDID eq '{}'".format(i.replace("'", "''")) for i in ids)
    code, j, n = tdx.get('v2/Road/Traffic/Live/VD/Freeway', {'$filter': flt}, name='vdlive_Freeway')
    if code == 200:
        return live_vds(j, now), f'$filter 篩選 OK，{n / 1024:.1f} KB'
    code2, j2, n2 = tdx.get('v2/Road/Traffic/Live/VD/Freeway', name='vdlive_all_Freeway')
    if code2 == 200:
        return live_vds(j2, now), f'$filter 回 HTTP {code} → 改抓全部 {n2 / 1024:.0f} KB'
    return None, f'$filter HTTP {code}、全部 HTTP {code2}'


# ------------------------------------------------------------------ vdtest：篩選與 LaneID
def cmd_vdtest(a, tdx):
    sections, _, vds, now = load_freeway(tdx, with_vd=True)
    x, y = xy(a.lat, a.lon)
    hit = sections.locate(x, y, a.heading)
    if hit is None:
        sys.exit('不在國道路段上')
    _, line = sections.path(*hit)
    ahead = vds.ahead(line, x, y, a.heading)
    if not ahead:
        sys.exit('前方 5 公里內沒有同向偵測器')
    ids = [v for v, _ in ahead]
    flt = ' or '.join("VDID eq '{}'".format(i.replace("'", "''")) for i in ids)
    code, j, n = tdx.get('v2/Road/Traffic/Live/VD/Freeway', {'$filter': flt}, name='vdlive_Freeway')
    print(f'\n$filter（{len(ids)} 支）：HTTP {code}，{n} bytes（傳輸）')
    if code == 200:
        got = {v.get('VDID') for v in items(j) if isinstance(v, dict)}
        print(f'  回傳 {len(got)} 支：' + ('只有要的那幾支 ✓' if got <= set(ids) else f'多了 {len(got - set(ids))} 支 → 篩選沒生效'))
    code2, j2, n2 = tdx.get('v2/Road/Traffic/Live/VD/Freeway', name='vdlive_all_Freeway')
    print(f'不篩選（全部國道）：HTTP {code2}，{n2 / 1024:.0f} KB（傳輸）→ 每分鐘抓一次約 {n2 * 60 / 1024 / 1024:.0f} MB/小時')
    src = j if code == 200 else j2
    print('\n前方偵測器原始車道（請對照實際：LaneID 0 是不是內側車道？LaneType 有沒有路肩？）')
    raw = {v.get('VDID'): v for v in items(src) if isinstance(v, dict)}
    for vid, d in ahead:
        v = raw.get(vid)
        if v is None:
            print(f'  {d:6.0f} m  {vid}：沒有資料')
            continue
        lanes = [ln for lf in v.get('LinkFlows') or [] for ln in (lf.get('Lanes') or [])]
        print(f'  {d:6.0f} m  {vid}  Status {v.get("Status")}  {v.get("DataCollectTime")}')
        for ln in sorted(lanes, key=lambda l: l.get('LaneID', 0)):
            print(f'      LaneID {ln.get("LaneID")}  LaneType {ln.get("LaneType")}  Speed {ln.get("Speed")}  '
                  f'Occupancy {ln.get("Occupancy")}')
    print(f'\nTDX 呼叫 {tdx.calls} 次')


# ------------------------------------------------------------------ selftest：同 test/tdx_freeway_test.dart 的離線案例
def cmd_selftest(_a=None):
    shapes = shrink_shapes({'SectionShapes': [
        {'SectionID': 'A', 'Geometry': 'LINESTRING(121.5 25.0, 121.5 25.009)'},
        {'SectionID': 'B', 'Geometry': 'LINESTRING(121.5 25.009, 121.5 25.027)'},
        {'SectionID': 'C', 'Geometry': 'LINESTRING(121.5 25.027, 121.5 25.045)'},
        {'SectionID': 'D', 'Geometry': 'LINESTRING(121.5 25.045, 121.5 25.063)'},
    ]})
    secs_ = Sections(shapes)
    x, y = xy(25.0, 121.5)
    hit = secs_.locate(x, y, 0)
    assert hit is not None
    path, line = secs_.path(*hit)
    ok = 0

    def check(cond, msg):
        nonlocal ok
        if not cond:
            raise AssertionError(msg)
        ok += 1

    q = queue_ahead(path, {'A': 90, 'B': 30, 'C': 20, 'D': 70})
    check(abs(q['d'] - path[1]['d0']) < .01 and abs(q['len'] - (path[3]['d0'] - path[1]['d0'])) < .01
          and q['min'] == 20 and q['avg'] == 25 and not q['open'], f'連續回堵 {q}')
    q = queue_ahead(path, {'A': 25, 'B': 30, 'C': 20, 'D': 10})
    check(q['d'] == 0 and q['open'], f'已在回堵、到路徑盡頭 {q}')
    check(not queue_ahead(path, {'A': 90, 'B': 30, 'D': 10})['open'], '沒資料要中斷')
    check(queue_ahead(path, {'A': 90, 'B': 90, 'C': 90, 'D': 10}) is None, '起點超過 3 公里不算')
    check(queue_ahead(path, {'A': 40, 'B': 40}) is None, '40 不算回堵')

    vds = VdIndex(shrink_vds({'VDs': [
        {'VDID': 'near', 'PositionLat': 25.001, 'PositionLon': 121.5, 'DetectionLinks': [{'Bearing': 'N'}]},
        {'VDID': 'n1', 'PositionLat': 25.016, 'PositionLon': 121.5, 'DetectionLinks': [{'Bearing': 'N'}]},
        {'VDID': 's1', 'PositionLat': 25.010, 'PositionLon': 121.5001, 'DetectionLinks': [{'Bearing': 'S'}]},
        {'VDID': 'far', 'PositionLat': 25.040, 'PositionLon': 121.5, 'DetectionLinks': [{'Bearing': 'N'}]},
        {'VDID': 'off', 'PositionLat': 25.010, 'PositionLon': 121.51},
    ]}))
    now = datetime.fromisoformat('2026-11-12T10:00:00+08:00').timestamp()
    live = live_vds({'VDLives': [
        {'VDID': 'near', 'Status': 0, 'DataCollectTime': '2026-11-12T09:59:00+08:00',
         'LinkFlows': [{'Lanes': [{'LaneID': 0, 'LaneType': 1, 'Speed': 95}]}]},
        {'VDID': 'n1', 'Status': 0, 'DataCollectTime': '2026-11-12T09:59:00+08:00',
         'LinkFlows': [{'Lanes': [{'LaneID': 2, 'LaneType': 1, 'Speed': 38}, {'LaneID': 0, 'LaneType': 1, 'Speed': 92.4},
                                  {'LaneID': 1, 'LaneType': 1, 'Speed': 85}, {'LaneID': 3, 'LaneType': 1, 'Speed': 0}]}]},
        {'VDID': 'far', 'Status': 1, 'LinkFlows': [{'Lanes': [{'LaneID': 0, 'Speed': 50}]}]},
        {'VDID': 'old', 'Status': 0, 'DataCollectTime': '2026-11-12T09:00:00+08:00',
         'LinkFlows': [{'Lanes': [{'LaneID': 0, 'Speed': 50}]}]},
    ]}, now)
    check(set(live) == {'near', 'n1'} and [l['speed'] for l in live['n1']] == [92, 85, 38], f'Live VD 解析 {live}')
    ahead = vds.ahead(line, x, y, 0)
    check([v for v, _ in ahead] == ['near', 'n1', 'far'], f'前方偵測器 {ahead}')
    la = lanes_ahead(ahead, live)
    check(la['vd'] == 'n1' and abs(la['d'] - 1769) < 5, f'車道車速 {la}')
    check(lanes_text(la) == '車道 1.8公里  內 92｜85｜38 外', lanes_text(la))

    q = {'d': 1500.0, 'len': 3500.0, 'avg': 28, 'min': 25, 'open': False}
    check(queue_text(q) == '回堵 1.5公里起 3.5公里｜均速 28', queue_text(q))
    check(drop_text(q, 90) == '車速驟降 前方1.5公里 降至25km', drop_text(q, 90))
    check(drop_text(q, 55) == '', '只快 30 不算驟降')
    check(drop_text({**q, 'd': 2500.0}, 90) == '', '超過 2 公里不算驟降')
    q0 = {'d': 0.0, 'len': 6000.0, 'avg': 20, 'min': 15, 'open': True}
    check(queue_text(q0) == '回堵中 還有 6.0公里以上｜均速 20', queue_text(q0))
    # 國道跨缺口（同 test/tdx_freeway_test.dart 'bridge'）
    def mk(rows):
        sh = shrink_shapes({'S': [{'SectionID': k, 'Geometry': f'LINESTRING(121.5 {a}, 121.5 {b})'} for k, a, b, _ in rows]})
        return Sections(sh, {k: {'name': k, 'road': r} for k, _, _, r in rows})
    g = mk([('A', 25.0, 25.009, 'R'), ('B', 25.018, 25.027, 'R'), ('E', 25.0095, 25.02, 'X')])
    pb, _ = g.path('A', 0.0, bridge=True)
    check([x['sid'] for x in pb] == ['A', 'B'] and abs(pb[1]['d0'] - 25.018 * KY + 25.0 * KY) < 1, f'跨缺口接同路 {pb}')
    pn, _ = g.path('A', 0.0, bridge=False)
    check([x['sid'] for x in pn] == ['A', 'E'], f'不跨缺口接別條路 {pn}')
    g2 = mk([('A', 25.0, 25.009, 'R'), ('C', 25.0077, 25.02, 'R')])
    check([x['sid'] for x in g2.path('A', 0.0, bridge=True)[0]] == ['A', 'C'], '重疊 ~150 m 也接得到')
    check([x['sid'] for x in g2.path('A', 0.0, bridge=False)[0]] == ['A'], '原規則接不到重疊')
    g3 = mk([('A', 25.0, 25.009, 'R'), ('F', 25.04, 25.05, 'R')])
    check([x['sid'] for x in g3.path('A', 0.0, bridge=True)[0]] == ['A'], '缺口超過 3 公里不接')
    # 線形畫過頭：下一段起點在本段終點前 ~885 m 的線上
    g4 = mk([('A', 25.0, 25.009, 'R'), ('C', 25.001, 25.02, 'R'), ('D', 25.0091, 25.03, 'R')])
    p4, _ = g4.path('A', 0.0, bridge=True)
    check([x['sid'] for x in p4][:2] == ['A', 'C'] and abs(p4[1]['d0'] - 0.001 * KY) < 1, f'畫過頭 {p4}')
    q4 = queue_ahead(p4[:2], {'A': 90, 'C': 30})
    check(abs(q4['d'] - 0.001 * KY) < 1 and abs(q4['len'] - (p4[1]['d1'] - p4[1]['d0'])) < 1, f'重疊不重複算長度 {q4}')
    print(f'✓ selftest 通過 {ok} 項（與 test/tdx_freeway_test.dart 相同案例）')


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('cmd', choices=['selftest', 'scan', 'point', 'vdtest'])
    # 優先順序：命令列 > 環境變數 > 程式開頭的 CLIENT_ID / CLIENT_SECRET
    ap.add_argument('--id', default=os.environ.get('TDX_CLIENT_ID') or CLIENT_ID)
    ap.add_argument('--secret', default=os.environ.get('TDX_CLIENT_SECRET') or CLIENT_SECRET)
    ap.add_argument('--kph', type=float, default=100.0, help='本車車速（車速驟降判斷用）')
    ap.add_argument('--road', default='', help='scan 只看這條路（RoadName 包含此字串，例：國道1號）')
    ap.add_argument('--queue-kph', type=int, default=QUEUE_KPH,
                    help=f'測試用：低於這個車速算回堵（opview 固定 {QUEUE_KPH}；沒塞車時可調高到 60 測邏輯）')
    ap.add_argument('--lat', type=float)
    ap.add_argument('--lon', type=float)
    ap.add_argument('--heading', type=float, help='行車方向（度，北 0、東 90、南 180、西 270）')
    ap.add_argument('--save', help='把抓到的 JSON 存到這個資料夾')
    ap.add_argument('--load', help='用存好的 JSON 重跑（不連 TDX）')
    a = ap.parse_args()
    if sys.stdout.encoding and sys.stdout.encoding.lower() not in ('utf-8', 'utf8'):
        try:
            sys.stdout.reconfigure(encoding='utf-8')  # Windows 主控台
        except Exception:
            pass
    if a.cmd == 'selftest':
        return cmd_selftest()
    if a.queue_kph != QUEUE_KPH:
        globals()['QUEUE_KPH'] = a.queue_kph
        print(f'⚠ 測試模式：回堵門檻改為 < {a.queue_kph} km/h（opview 實際是 < 40）')
    if a.cmd in ('point', 'vdtest') and (a.lat is None or a.lon is None or a.heading is None):
        sys.exit(f'{a.cmd} 需要 --lat --lon --heading')
    tdx = Tdx(a.id, a.secret, a.save, a.load)
    {'scan': cmd_scan, 'point': cmd_point, 'vdtest': cmd_vdtest}[a.cmd](a, tdx)


if __name__ == '__main__':
    main()
