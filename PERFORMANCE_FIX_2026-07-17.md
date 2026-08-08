# GharTek – Backend/Database Performance Fix (17 July 2026)

## Problem (jo report hua)

- Bohot saare users online hone par app open nahi ho rahi thi.
- Naye orders **aate the phir gaib ho jate the** (rider/admin par).
- Server database se data theek se serve nahi kar raha tha.

## Logs se mila exact issue

**Backend (`ghartek_backend`):**
```
[rtdb] fast child-equal query failed: timeout exceeded when trying to connect
[api] /v1/query timeout exceeded when trying to connect
[api] /v1/get   timeout exceeded when trying to connect
```
→ Postgres pool ke saare connections busy, nayi query ko connection hi nahi mil raha tha.

**Postgres (`ghartek_pg`):**
```
could not send data to client: Broken pipe
connection to client lost (FATAL)
```
→ Queries beech mein hi backend chhod raha tha (timeout hone par).

### "Orders aate hain phir gaib" ka mechanism
Naya order WebSocket se aata → screen par dikhta → phir app `/v1/query` / `/v1/get` se reload karti → us waqt connection na milne se query **khali/fail** → list khali → **order gaib**.

## Root cause (NOTE: data volume problem nahi thi — sirf ~8 orders, 3 active)

1. **Connection amplifier** – status-query ke baad har matched order ke liye alag `getValue` (alag DB connection). Ek hi request 40+ connections le leti thi → pool foran khatam.
2. **`/v1/queue-stats` slow query** – har order (history samet) par 5 correlated subqueries. Ek call ~**21 second** tak connection pakde rakhti thi (customer app ise frequently call karti hai) → pool choke.
3. **Koi statement timeout nahi** – ek atki query connection ko hamesha ke liye block kar deti thi → cascade failure.

## Fixes (sab live deploy + verify)

| # | Fix | File |
|---|-----|------|
| 1 | Postgres pool `max` **30 → 50** | `backend/src/db.js` |
| 2 | `statement_timeout` / `query_timeout` / `idle_in_transaction_session_timeout` = **15s** (atki query connection turant chhode) | `backend/src/db.js` |
| 3 | Fast child-equal query mein **bounded concurrency** (max 8 conn/request) — 40-connection amplifier khatam | `backend/src/rtdb.js` |
| 4 | `getQueueStats` optimize — pehle terminal (delivered/cancelled) orders filter, subqueries sirf active orders par. **21.9s → 1.3ms** | `backend/src/rtdb.js` |
| 5 | 2 partial index banaye: `%/status` aur `%/userId` (future scale ke liye fast queries) | `backend/sql/001_schema.sql` + live DB |

### Naye indexes
```sql
CREATE INDEX IF NOT EXISTS rtdb_status_value_idx
  ON rtdb_nodes (db_name, value, path text_pattern_ops)
  WHERE path LIKE '%/status';

CREATE INDEX IF NOT EXISTS rtdb_userid_value_idx
  ON rtdb_nodes (db_name, value, path text_pattern_ops)
  WHERE path LIKE '%/userId';
```

### Naye environment variables (defaults set hain, chahein to tune karein)
```
DB_POOL_MAX=50
DB_STATEMENT_TIMEOUT_MS=15000
DB_QUERY_TIMEOUT_MS=15000
DB_IDLE_TX_TIMEOUT_MS=15000
DB_IDLE_TIMEOUT_MS=30000
DB_CONN_TIMEOUT_MS=10000
```

## Deployment (server: 168.144.126.109)

1. Purani `db.js` / `rtdb.js` ka backup (`*.bak.*`) `/opt/ghartek-backend/src/` par.
2. Nayi files `scp` se copy.
3. Indexes `CREATE INDEX CONCURRENTLY` se live DB par (table lock nahi hua).
4. `docker compose -f docker-compose.prod.yml up -d --build backend` se rebuild + restart.
5. Health check: `{"ok":true,"service":"ghartek-backend","spaces":true}`.

## Verification (deploy ke baad live)

| Metric | Pehle | Ab |
|--------|-------|-----|
| Backend errors (60s window) | sekron timeout | **0** |
| Slow queries (>2s) | 12–22s | **0** |
| DB connections | 48+ (saturate) | **19 / 1 active** |
| `queue-stats` query | 21.9s | **1.3ms** |

## Zaroori note

- Ye sab **backend + database** changes hain. Server par live hain.
- **Koi nayi APK/AAB build ki zaroorat nahi** — purani installed apps par bhi orders theek load honge.
- Data chhota hai (~8 orders); masla connection handling ka tha jo ab theek hai.

## Rollback (agar zaroorat pade)
```bash
cd /opt/ghartek-backend/src
# latest backup dekho:
ls -t db.js.bak* rtdb.js.bak*
# restore + rebuild:
cp db.js.bak.<timestamp> db.js
cp rtdb.js.bak.<timestamp> rtdb.js
cd /opt/ghartek-backend && docker compose -f docker-compose.prod.yml up -d --build backend
```
(Indexes chhodne se koi nuksan nahi; chahein to `DROP INDEX rtdb_status_value_idx, rtdb_userid_value_idx;`)

---

# Update (17 July 2026 — dobara wahi problem: order aa k gaib) — PERMANENT FIX

## Asal masla is baar (pichhli baar wala nahi tha)
Pichhli baar ka fix **connection pool** ka tha. Ye masla alag hai: **read-cache coherency race**.

- Backend mein `rtdb.js` ke andar 15s ka **read cache** hai (`READ_CACHE_TTL_MS`).
- Har write (`setValue/updateValue/pushValue/removeValue/compareAndSet`) **COMMIT se PEHLE** `invalidateCache()` call karti thi.
- Jab load zyada ho (bohot users online), commit se just pehle wali chhoti window mein koi doosri request `shop-orders` parent ko read kar leti hai. Us waqt naya order abhi **visible nahi** hota (READ COMMITTED), to cache mein **purana tree (naye order ke baghair)** dobara set ho jata hai.
- Phir COMMIT + `pg_notify` hota hai → WebSocket change handler subscription recompute karta hai `getValue` se → **cache HIT (stale)** → riders/admin ko order list **naye order ke baghair** milti hai → **order gaib**.
- 15s TTL khatam hone par hi wapas aata hai. Isi liye "kuch der k liye aata hai, kuch k liye nahi" — random, aur load par zyada.

## Permanent fix (2 hisse)
1. **Cache ab COMMIT ke BAAD invalidate hoti hai** har writer mein (`backend/src/rtdb.js`). Commit-window wali stale re-cache ab foran clear ho jati hai.
2. **Realtime change-listener bhi recompute se pehle cache invalidate karta hai** (`backend/src/realtime.js`). `pg_notify` sirf commit ke baad deliver hota hai, is liye recompute hamesha **fresh** data padhega. Ye external writer (import script) aur future multi-instance ko bhi cover karta hai.

| # | Fix | File |
|---|-----|------|
| 1 | `invalidateCache()` ko COMMIT ke baad move kiya (5 writers) | `backend/src/rtdb.js` |
| 2 | `invalidateCache` export kiya | `backend/src/rtdb.js` |
| 3 | `changes.on("change")` par recompute se pehle cache invalidate | `backend/src/realtime.js` |

## Deployment (server: 168.144.126.109)
```bash
# nayi rtdb.js + realtime.js /opt/ghartek-backend/src/ par scp karo (backup lena)
cd /opt/ghartek-backend
docker compose -f docker-compose.prod.yml up -d --build backend
# health check:
curl -s https://168-144-126-109.sslip.io/health   # {"ok":true,...}
```
- Sirf **backend** change hai — **nayi APK/AAB ki zaroorat nahi**.
- Koi DB migration/index nahi; sirf code.
