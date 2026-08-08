const { pool, notifyChange } = require("./db");
const { generatePushId } = require("./pushid");
const {
  resolveServerValues,
  flattenLeaves,
  rebuildTree,
  isPlainObject,
  joinPath,
  normalizePath,
} = require("./tree");

// Short-lived read cache — shops/settings are fetched on almost every screen.
const READ_CACHE_TTL_MS = parseInt(process.env.RTDB_READ_CACHE_MS || "15000", 10);
const readCache = new Map();

function cacheKey(dbName, path) {
  return `${dbName}::${path}`;
}

function getCached(dbName, path) {
  const hit = readCache.get(cacheKey(dbName, path));
  if (hit && hit.expiry > Date.now()) return hit.value;
  return undefined;
}

function setCached(dbName, path, value) {
  readCache.set(cacheKey(dbName, path), {
    value,
    expiry: Date.now() + READ_CACHE_TTL_MS,
  });
}

function invalidateCache(dbName, paths) {
  const norms = (paths || []).map((p) => normalizePath(p));
  if (!norms.length) return;
  for (const key of readCache.keys()) {
    const sep = key.indexOf("::");
    if (sep < 0) continue;
    const db = key.slice(0, sep);
    const cp = key.slice(sep + 2);
    if (db !== dbName) continue;
    for (const norm of norms) {
      if (cp === norm || cp.startsWith(`${norm}/`) || norm.startsWith(`${cp}/`)) {
        readCache.delete(key);
        break;
      }
    }
  }
}

// ---- reads --------------------------------------------------------------

async function getValue(dbName, rawPath, { skipCache = false } = {}) {
  const path = normalizePath(rawPath);
  if (!skipCache) {
    const cached = getCached(dbName, path);
    if (cached !== undefined) return cached;
  }
  const { rows } = await pool.query(
    `SELECT path, value FROM rtdb_nodes
      WHERE db_name = $1 AND (path = $2 OR path LIKE $3)`,
    [dbName, path, likePrefix(path)]
  );
  const tree = rebuildTree(path, rows);
  if (!skipCache) setCached(dbName, path, tree);
  return tree;
}

// Shop listing / checkout only need metadata — skip heavy menu/product subtrees.
const SHALLOW_EXCLUDES = ["menu", "products", "categories", "subcategories", "deals", "items"];

async function getValueShallow(dbName, rawPath, { skipCache = false } = {}) {
  const path = normalizePath(rawPath);
  const shallowKey = `${cacheKey(dbName, path)}::shallow`;
  if (!skipCache) {
    const hit = readCache.get(shallowKey);
    if (hit && hit.expiry > Date.now()) return hit.value;
  }

  const excludeClauses = SHALLOW_EXCLUDES.map(
    (_, i) => `AND path NOT LIKE $${4 + i} ESCAPE '\\'`
  ).join("\n           ");
  const excludeParams = SHALLOW_EXCLUDES.map(
    (seg) => `%/${seg.replace(/([%_\\])/g, "\\$1")}/%`
  );

  const { rows } = await pool.query(
    `SELECT path, value FROM rtdb_nodes
       WHERE db_name = $1 AND (path = $2 OR path LIKE $3)
           ${excludeClauses}`,
    [dbName, path, likePrefix(path), ...excludeParams]
  );
  const tree = rebuildTree(path, rows);
  if (!skipCache) {
    readCache.set(shallowKey, { value: tree, expiry: Date.now() + READ_CACHE_TTL_MS });
  }
  return tree;
}

function likePrefix(path) {
  // Escape LIKE wildcards in the stored path prefix, then match 'path/%'.
  const escaped = path.replace(/([%_\\])/g, "\\$1");
  return `${escaped}/%`;
}

// ---- writes -------------------------------------------------------------

async function setValue(dbName, rawPath, value) {
  const path = normalizePath(rawPath);
  const now = Date.now();
  const client = await pool.connect();
  try {
    await client.query("BEGIN");
    await writeNode(client, dbName, path, value, now);
    await notifyChange(client, dbName, [path]);
    await client.query("COMMIT");
    // Invalidate AFTER commit: if we clear the cache before commit, a concurrent
    // read in the window before COMMIT re-caches the pre-write tree (the new data
    // isn't visible yet), and the change-driven refresh then serves that stale
    // copy — the "order appears then disappears" bug.
    invalidateCache(dbName, [path]);
  } catch (e) {
    await client.query("ROLLBACK");
    throw e;
  } finally {
    client.release();
  }
}

// RTDB update(): merge each named child; keys may be multi-segment paths and
// a null value deletes that location. Siblings not named are left untouched.
async function updateValue(dbName, rawPath, updates) {
  const base = normalizePath(rawPath);
  if (!isPlainObject(updates)) {
    throw new Error("update() expects an object of child paths");
  }
  const now = Date.now();
  const changed = [];
  const client = await pool.connect();
  try {
    await client.query("BEGIN");
    for (const [key, val] of Object.entries(updates)) {
      const target = joinPath(base, key);
      await writeNode(client, dbName, target, val, now);
      changed.push(target);
    }
    await notifyChange(client, dbName, changed.length ? changed : [base]);
    await client.query("COMMIT");
    invalidateCache(dbName, changed.length ? changed : [base]);
  } catch (e) {
    await client.query("ROLLBACK");
    throw e;
  } finally {
    client.release();
  }
}

async function pushValue(dbName, rawPath, value) {
  const base = normalizePath(rawPath);
  const key = generatePushId();
  const target = joinPath(base, key);
  const now = Date.now();
  const client = await pool.connect();
  try {
    await client.query("BEGIN");
    await writeNode(client, dbName, target, value, now);
    await notifyChange(client, dbName, [target]);
    await client.query("COMMIT");
    invalidateCache(dbName, [target, base]);
  } catch (e) {
    await client.query("ROLLBACK");
    throw e;
  } finally {
    client.release();
  }
  return key;
}

async function removeValue(dbName, rawPath) {
  const path = normalizePath(rawPath);
  const client = await pool.connect();
  try {
    await client.query("BEGIN");
    await deletePrefix(client, dbName, path);
    await notifyChange(client, dbName, [path]);
    await client.query("COMMIT");
    invalidateCache(dbName, [path]);
  } catch (e) {
    await client.query("ROLLBACK");
    throw e;
  } finally {
    client.release();
  }
}

// Replace the subtree at `target` with `value` (a "set" on that location).
async function writeNode(client, dbName, target, value, now) {
  await deletePrefix(client, dbName, target);
  const resolved = resolveServerValues(value, now);
  if (resolved === null || resolved === undefined) return; // delete only
  const leaves = flattenLeaves(target, resolved);
  if (leaves.length === 0) return; // empty object == no data in RTDB
  const paths = leaves.map((l) => l[0]);
  const values = leaves.map((l) => JSON.stringify(l[1]));
  await client.query(
    `INSERT INTO rtdb_nodes (db_name, path, value, updated_at)
       SELECT $1, p, v::jsonb, now()
         FROM unnest($2::text[], $3::text[]) AS t(p, v)
     ON CONFLICT (db_name, path)
       DO UPDATE SET value = EXCLUDED.value, updated_at = now()`,
    [dbName, paths, values]
  );
}

async function deletePrefix(client, dbName, path) {
  await client.query(
    `DELETE FROM rtdb_nodes
      WHERE db_name = $1 AND (path = $2 OR path LIKE $3)`,
    [dbName, path, likePrefix(path)]
  );
}

// ---- transaction (compare-and-set) --------------------------------------

function canonical(v) {
  if (Array.isArray(v)) return "[" + v.map(canonical).join(",") + "]";
  if (isPlainObject(v)) {
    return (
      "{" +
      Object.keys(v)
        .sort()
        .map((k) => JSON.stringify(k) + ":" + canonical(v[k]))
        .join(",") +
      "}"
    );
  }
  return JSON.stringify(v === undefined ? null : v);
}

// Atomically write `value` only if the stored value still equals `expected`.
// Used to implement RTDB runTransaction() with client-side retries.
async function compareAndSet(dbName, rawPath, expected, value) {
  const path = normalizePath(rawPath);
  const client = await pool.connect();
  try {
    await client.query("BEGIN");
    // Lock the affected rows for the duration of the tx.
    const { rows } = await client.query(
      `SELECT path, value FROM rtdb_nodes
        WHERE db_name = $1 AND (path = $2 OR path LIKE $3) FOR UPDATE`,
      [dbName, path, likePrefix(path)]
    );
    const current = rebuildTree(path, rows);
    if (canonical(current) !== canonical(expected ?? null)) {
      await client.query("ROLLBACK");
      return { committed: false, current };
    }
    await writeNode(client, dbName, path, value, Date.now());
    await notifyChange(client, dbName, [path]);
    await client.query("COMMIT");
    invalidateCache(dbName, [path]);
    return { committed: true, current: value };
  } catch (e) {
    await client.query("ROLLBACK");
    throw e;
  } finally {
    client.release();
  }
}

// ---- queries ------------------------------------------------------------

// Mirrors RTDB query semantics over the children of `path`.
// opts: { orderBy: 'key'|'value'|'child', childKey, equalTo, startAt, endAt,
//         limitToFirst, limitToLast }
async function queryChildren(dbName, rawPath, opts = {}) {
  const path = normalizePath(rawPath);
  const orderBy = opts.orderBy || "key";

  // Fast path: orderByChild + equalTo — avoids downloading the entire subtree
  // (e.g. all shop-orders) when we only need one user's orders.
  if (
    orderBy === "child" &&
    opts.childKey &&
    !String(opts.childKey).includes("/") &&
    Object.prototype.hasOwnProperty.call(opts, "equalTo") &&
    opts.startAt === undefined &&
    opts.endAt === undefined
  ) {
    const fast = await queryChildrenByChildEqual(
      dbName,
      path,
      String(opts.childKey),
      opts.equalTo,
      opts
    );
    if (fast) return fast;
  }

  const tree = await getValue(dbName, path);
  const map = isPlainObject(tree) ? tree : {};
  let entries = Object.keys(map).map((k) => ({ key: k, value: map[k] }));

  const sortKeyOf = (e) => {
    if (orderBy === "key") return e.key;
    if (orderBy === "value") return e.value;
    // orderBy child (childKey may be nested a/b/c)
    return resolveChild(e.value, opts.childKey);
  };

  entries.forEach((e) => (e._sk = sortKeyOf(e)));

  if (Object.prototype.hasOwnProperty.call(opts, "equalTo")) {
    entries = entries.filter((e) => looseEq(e._sk, opts.equalTo));
  }
  if (Object.prototype.hasOwnProperty.call(opts, "startAt")) {
    entries = entries.filter((e) => cmp(e._sk, opts.startAt) >= 0);
  }
  if (Object.prototype.hasOwnProperty.call(opts, "endAt")) {
    entries = entries.filter((e) => cmp(e._sk, opts.endAt) <= 0);
  }

  entries.sort((a, b) => {
    const c = cmp(a._sk, b._sk);
    return c !== 0 ? c : cmp(a.key, b.key);
  });

  if (opts.limitToFirst != null) entries = entries.slice(0, opts.limitToFirst);
  if (opts.limitToLast != null) entries = entries.slice(-opts.limitToLast);

  const order = entries.map((e) => e.key);
  const values = {};
  for (const e of entries) values[e.key] = e.value;
  return { order, values };
}

// SQL-backed filter for `.orderByChild(x).equalTo(y)` without loading siblings.
async function queryChildrenByChildEqual(dbName, path, childKey, equalTo, opts) {
  try {
    const childSuffix = `%/${childKey.replace(/([%_\\])/g, "\\$1")}`;
    const jsonCandidates = [JSON.stringify(equalTo)];
    if (typeof equalTo === "string" && equalTo !== "" && !Number.isNaN(Number(equalTo))) {
      jsonCandidates.push(JSON.stringify(Number(equalTo)));
    }
    if (typeof equalTo === "number") {
      jsonCandidates.push(JSON.stringify(String(equalTo)));
    }

    const { rows } = await pool.query(
      `SELECT path FROM rtdb_nodes
         WHERE db_name = $1
           AND path LIKE $2 ESCAPE '\\'
           AND path LIKE $3 ESCAPE '\\'
           AND value = ANY($4::jsonb[])`,
      [dbName, likePrefix(path), childSuffix, jsonCandidates]
    );

    const prefix = `${path}/`;
    const idSet = new Set();
    for (const row of rows) {
      if (!row.path.startsWith(prefix)) continue;
      const id = row.path.slice(prefix.length).split("/")[0];
      if (id) idSet.add(id);
    }

    const orderIds = [...idSet];
    const values = {};

    // Fetch each matched order's subtree, but with BOUNDED CONCURRENCY. Doing an
    // unbounded Promise.all here meant e.g. 40 matching orders grabbed 40 pooled
    // connections from ONE request, which exhausted the pool under load and
    // produced cascading "timeout when trying to connect" errors. Each getValue()
    // is a single indexed range scan (path LIKE 'parent/id/%'), so capping how
    // many run at once keeps every request cheap on the pool while staying fast.
    const CONCURRENCY = 8;
    for (let i = 0; i < orderIds.length; i += CONCURRENCY) {
      const batch = orderIds.slice(i, i + CONCURRENCY);
      await Promise.all(
        batch.map(async (id) => {
          values[id] = await getValue(dbName, joinPath(path, id));
        })
      );
    }

    let entries = orderIds.map((key) => ({ key, value: values[key] }));
    entries.sort((a, b) => cmp(a.key, b.key));

    if (opts.limitToFirst != null) entries = entries.slice(0, opts.limitToFirst);
    if (opts.limitToLast != null) entries = entries.slice(-opts.limitToLast);

    const order = entries.map((e) => e.key);
    const out = {};
    for (const e of entries) out[e.key] = e.value;
    return { order, values: out };
  } catch (e) {
    console.error("[rtdb] fast child-equal query failed:", e.message);
    return null;
  }
}

const QUEUE_TERMINAL = new Set([
  "delivered",
  "cancelled",
  "canceled",
  "rejected",
  "merchant_rejected",
]);

// Fast Islamabad queue stats without downloading entire shop-orders trees.
async function getQueueStats(dbName, tenantPath, userId) {
  const base = normalizePath(tenantPath);
  const combined = [];

  for (const [collection, queueType] of [
    ["shop-orders", "shop"],
    ["custom-orders", "custom"],
  ]) {
    const prefix = joinPath(base, collection);
    // Only active orders matter for the queue. Filtering out terminal statuses
    // in the CTE FIRST (served by the partial rtdb_status_value_idx, value is in
    // the index so no heap fetch) means the 5 correlated field lookups run only
    // for the handful of active orders instead of for every order ever placed.
    // Previously this scanned all history and did 5 subqueries per row (~20s+).
    const { rows } = await pool.query(
      `WITH active AS (
         SELECT n.path AS path, n.value #>> '{}' AS status
         FROM rtdb_nodes n
         WHERE n.db_name = $1
           AND n.path LIKE $2
           AND n.path LIKE '%/status'
           AND n.value NOT IN (
             '"delivered"'::jsonb, '"cancelled"'::jsonb, '"canceled"'::jsonb,
             '"rejected"'::jsonb, '"merchant_rejected"'::jsonb
           )
       )
       SELECT
         (regexp_match(a.path, '${collection}/([^/]+)/status$'))[1] AS order_id,
         a.status AS status,
         COALESCE(
           (SELECT c.value #>> '{}' FROM rtdb_nodes c
             WHERE c.db_name = $1
               AND c.path = regexp_replace(a.path, '/status$', '/createdAtClient')),
           (SELECT c.value #>> '{}' FROM rtdb_nodes c
             WHERE c.db_name = $1
               AND c.path = regexp_replace(a.path, '/status$', '/createdAt')),
           '0'
         ) AS created_ts,
         (SELECT u.value #>> '{}' FROM rtdb_nodes u
           WHERE u.db_name = $1
             AND u.path = regexp_replace(a.path, '/status$', '/userId')) AS user_id,
         (SELECT d.value #>> '{}' FROM rtdb_nodes d
           WHERE d.db_name = $1
             AND d.path = regexp_replace(a.path, '/status$', '/isInstantOrder')) AS is_instant_raw,
         (SELECT d.value #>> '{}' FROM rtdb_nodes d
           WHERE d.db_name = $1
             AND d.path = regexp_replace(a.path, '/status$', '/deliverySpeed')) AS delivery_speed
       FROM active a`,
      [dbName, likePrefix(prefix)]
    );

    for (const row of rows) {
      const orderId = row.order_id;
      if (!orderId) continue;
      const status = String(row.status || "").toLowerCase().trim();
      if (QUEUE_TERMINAL.has(status)) continue;
      const isInstant =
        String(row.is_instant_raw || "").toLowerCase() === "true" ||
        String(row.delivery_speed || "").toLowerCase() === "instant";
      combined.push({
        orderId,
        queueType,
        userId: row.user_id || "",
        ts: parseInt(row.created_ts, 10) || 0,
        isInstant,
      });
    }
  }

  combined.sort((a, b) => a.ts - b.ts);

  const positions = {};
  if (userId) {
    for (let i = 0; i < combined.length; i++) {
      const o = combined[i];
      if (o.userId === userId) {
        positions[`${o.queueType}:${o.orderId}`] = i + 1;
      }
    }
  }

  const shopCount = combined.filter((o) => o.queueType === "shop").length;
  const customCount = combined.filter((o) => o.queueType === "custom").length;
  const instantOnly = combined.filter(
    (o) => o.queueType === "shop" && o.isInstant
  );

  const instantPositions = {};
  if (userId) {
    for (let i = 0; i < instantOnly.length; i++) {
      const o = instantOnly[i];
      if (o.userId === userId) {
        instantPositions[`${o.queueType}:${o.orderId}`] = i + 1;
      }
    }
  }

  return {
    activeCount: combined.length,
    shopCount,
    customCount,
    instantCount: instantOnly.length,
    positions,
    instantPositions,
  };
}

function resolveChild(value, childKey) {
  if (!childKey) return null;
  let node = value;
  for (const seg of String(childKey).split("/")) {
    if (!isPlainObject(node)) return null;
    node = node[seg];
  }
  return node === undefined ? null : node;
}

function looseEq(a, b) {
  if (a === b) return true;
  // RTDB treats numeric strings and numbers distinctly; keep strict but
  // tolerate number/string mismatch that the app sometimes produces.
  if (a == null || b == null) return false;
  return String(a) === String(b);
}

// RTDB type ordering: null < boolean < number < string.
function typeRank(v) {
  if (v === null || v === undefined) return 0;
  if (typeof v === "boolean") return 1;
  if (typeof v === "number") return 2;
  if (typeof v === "string") return 3;
  return 4;
}

function cmp(a, b) {
  const ra = typeRank(a);
  const rb = typeRank(b);
  if (ra !== rb) return ra - rb;
  if (ra === 0) return 0;
  if (ra === 1) return a === b ? 0 : a ? 1 : -1;
  if (ra === 2) return a - b;
  return a < b ? -1 : a > b ? 1 : 0;
}

module.exports = {
  getValue,
  getValueShallow,
  setValue,
  updateValue,
  pushValue,
  removeValue,
  compareAndSet,
  queryChildren,
  getQueueStats,
  invalidateCache,
};
