const { WebSocketServer } = require("ws");
const crypto = require("crypto");
const { changes } = require("./db");
const { getValue, queryChildren, invalidateCache } = require("./rtdb");
const { isPlainObject, normalizePath } = require("./tree");

// One WebSocket carries many subscriptions. Each subscription mirrors a
// Firebase listener (onValue / onChildAdded / onChildChanged / onChildRemoved)
// on a path, optionally with a query. When the underlying Postgres data
// changes we recompute the affected subscriptions and push events.

function hash(v) {
  return crypto.createHash("md5").update(JSON.stringify(v ?? null)).digest("hex");
}

function affects(changedPath, subPath) {
  if (changedPath === "*") return true;
  if (changedPath === subPath) return true;
  if (changedPath.startsWith(subPath + "/")) return true; // descendant changed
  if (subPath.startsWith(changedPath + "/")) return true; // ancestor changed
  return false;
}

async function computeChildren(sub) {
  // Returns an ordered array of { key, value } honouring any query.
  if (sub.query && Object.keys(sub.query).length > 0) {
    const { order, values } = await queryChildren(sub.db, sub.path, sub.query);
    return order.map((k) => ({ key: k, value: values[k] }));
  }
  const tree = await getValue(sub.db, sub.path);
  if (!isPlainObject(tree)) return [];
  return Object.keys(tree).map((k) => ({ key: tree[k] !== undefined ? k : k, value: tree[k] }));
}

async function computeValue(sub) {
  if (sub.query && Object.keys(sub.query).length > 0) {
    const { order, values } = await queryChildren(sub.db, sub.path, sub.query);
    if (order.length === 0) return { value: null, order: [] };
    const out = {};
    for (const k of order) out[k] = values[k];
    return { value: out, order };
  }
  return { value: await getValue(sub.db, sub.path), order: null };
}

function attachWebSocket(server) {
  const wss = new WebSocketServer({ server, path: "/rtdb" });

  wss.on("connection", (ws) => {
    ws.isAlive = true;
    ws.subs = new Map(); // subId -> sub
    ws.on("pong", () => (ws.isAlive = true));

    ws.on("message", async (raw) => {
      let msg;
      try {
        msg = JSON.parse(raw.toString());
      } catch {
        return;
      }
      if (msg.type === "subscribe") await handleSubscribe(ws, msg);
      else if (msg.type === "unsubscribe") ws.subs.delete(msg.subId);
      else if (msg.type === "ping") send(ws, { type: "pong" });
    });

    ws.on("close", () => ws.subs.clear());
    ws.on("error", () => ws.subs.clear());
  });

  // Heartbeat to drop dead sockets.
  const interval = setInterval(() => {
    wss.clients.forEach((ws) => {
      if (ws.isAlive === false) return ws.terminate();
      ws.isAlive = false;
      try { ws.ping(); } catch {}
    });
  }, 30000);
  wss.on("close", () => clearInterval(interval));

  // React to data changes — DEBOUNCED + COALESCED.
  //
  // Problem this solves: many clients (every rider/admin dashboard) subscribe to
  // the same big path (e.g. `shop-orders`). Without coalescing, a single order
  // change made the server run one full-tree read PER connected client, which
  // exhausted the Postgres pool under load and stalled everything (the app then
  // failed to open). Here we (1) batch a burst of changes over a short window
  // and (2) compute each unique (db, path, query) ONCE per flush and reuse the
  // result for every subscriber that needs it.
  let pending = new Map(); // db -> Set(changedPaths)
  let flushTimer = null;

  function scheduleFlush() {
    if (flushTimer) return;
    flushTimer = setTimeout(() => {
      flushTimer = null;
      flushChanges().catch((e) =>
        console.error("[rt] flush failed:", e.message)
      );
    }, 60);
  }

  async function flushChanges() {
    if (pending.size === 0) return;
    const batch = pending;
    pending = new Map();

    // Per-flush memoization: identical (db, path, query) work runs a single
    // query and every matching subscriber shares the same promise/result.
    const memo = new Map();
    const memoKey = (kind, sub) =>
      `${kind}::${sub.db}::${sub.path}::${JSON.stringify(sub.query || null)}`;
    const computeValueCached = (sub) => {
      const key = memoKey("v", sub);
      let p = memo.get(key);
      if (!p) {
        p = computeValue(sub);
        memo.set(key, p);
      }
      return p;
    };
    const computeChildrenCached = (sub) => {
      const key = memoKey("c", sub);
      let p = memo.get(key);
      if (!p) {
        p = computeChildren(sub);
        memo.set(key, p);
      }
      return p;
    };

    for (const ws of wss.clients) {
      if (!ws.subs || ws.subs.size === 0) continue;
      for (const sub of ws.subs.values()) {
        const set = batch.get(sub.db);
        if (!set) continue;
        let hit = false;
        for (const p of set) {
          if (affects(p, sub.path)) {
            hit = true;
            break;
          }
        }
        if (!hit) continue;
        try {
          await refresh(ws, sub, computeValueCached, computeChildrenCached);
        } catch (e) {
          console.error("[rt] refresh failed:", e.message);
        }
      }
    }
  }

  changes.on("change", ({ db, paths }) => {
    // Drop any stale cached reads for the changed paths BEFORE we recompute
    // subscriptions. pg_notify only delivers after COMMIT, so the follow-up
    // getValue() in flushChanges is guaranteed to read the freshly committed
    // data. This closes the race where a concurrent read had re-cached the
    // pre-write tree, which made new orders appear then disappear. It also
    // makes the cache coherent for any external writer (import script) and
    // future multi-instance deployments.
    invalidateCache(db, paths || []);
    let set = pending.get(db);
    if (!set) {
      set = new Set();
      pending.set(db, set);
    }
    for (const p of paths || []) set.add(p);
    scheduleFlush();
  });

  return wss;
}

async function handleSubscribe(ws, msg) {
  const sub = {
    subId: msg.subId,
    db: msg.db || "main",
    path: normalizePath(msg.path),
    event: msg.event || "value",
    query: msg.query || null,
    childState: new Map(), // key -> hash, for child_* diffing
  };
  ws.subs.set(sub.subId, sub);

  if (sub.event === "value") {
    const { value, order } = await computeValue(sub);
    send(ws, { type: "event", subId: sub.subId, event: "value", value, order });
    return;
  }

  // child_* : establish baseline and, for child_added, replay existing kids.
  const kids = await computeChildren(sub);
  let prevKey = null;
  for (const { key, value } of kids) {
    sub.childState.set(key, hash(value));
    if (sub.event === "child_added") {
      send(ws, {
        type: "event", subId: sub.subId, event: "child_added",
        key, value, prevKey,
      });
    }
    prevKey = key;
  }
}

async function refresh(
  ws,
  sub,
  computeValueFn = computeValue,
  computeChildrenFn = computeChildren
) {
  if (sub.event === "value") {
    const { value, order } = await computeValueFn(sub);
    send(ws, { type: "event", subId: sub.subId, event: "value", value, order });
    return;
  }

  const kids = await computeChildrenFn(sub);
  const nextState = new Map();
  let prevKey = null;
  for (const { key, value } of kids) {
    const h = hash(value);
    nextState.set(key, h);
    const had = sub.childState.has(key);
    if (!had && sub.event === "child_added") {
      send(ws, { type: "event", subId: sub.subId, event: "child_added", key, value, prevKey });
    } else if (had && sub.childState.get(key) !== h && sub.event === "child_changed") {
      send(ws, { type: "event", subId: sub.subId, event: "child_changed", key, value, prevKey });
    }
    prevKey = key;
  }
  if (sub.event === "child_removed") {
    for (const key of sub.childState.keys()) {
      if (!nextState.has(key)) {
        send(ws, { type: "event", subId: sub.subId, event: "child_removed", key, value: null });
      }
    }
  }
  sub.childState = nextState;
}

function send(ws, obj) {
  if (ws.readyState === ws.OPEN) {
    try { ws.send(JSON.stringify(obj)); } catch {}
  }
}

module.exports = { attachWebSocket };
