const { Pool, Client } = require("pg");
const { EventEmitter } = require("events");

const connectionString =
  process.env.DATABASE_URL ||
  "postgres://ghartek:ghartek_local_pw@localhost:5433/ghartek";

// Pool sizing matters under load: with too few connections, concurrent user
// requests queue behind each other and time out (the app then fails to open).
// Keep this comfortably below Postgres `max_connections` (default 100).
const POOL_MAX = parseInt(process.env.DB_POOL_MAX || "50", 10);

const pool = new Pool({
  connectionString,
  max: POOL_MAX,
  // Reclaim idle connections so the pool doesn't stay pinned.
  idleTimeoutMillis: parseInt(process.env.DB_IDLE_TIMEOUT_MS || "30000", 10),
  // Fail fast instead of hanging forever when the pool is saturated.
  connectionTimeoutMillis: parseInt(
    process.env.DB_CONN_TIMEOUT_MS || "10000",
    10
  ),
  // Never let a single slow query hold a pooled connection indefinitely — this
  // is what caused cascading "timeout exceeded when trying to connect" errors
  // under load. A stuck query is aborted and its connection returned to the pool.
  statement_timeout: parseInt(process.env.DB_STATEMENT_TIMEOUT_MS || "15000", 10),
  query_timeout: parseInt(process.env.DB_QUERY_TIMEOUT_MS || "15000", 10),
  idle_in_transaction_session_timeout: parseInt(
    process.env.DB_IDLE_TX_TIMEOUT_MS || "15000",
    10
  ),
});

// Never let an unexpected idle-client error crash the whole backend.
pool.on("error", (err) => {
  console.error("[db] idle client error:", err.message);
});

// Dedicated long-lived connection for LISTEN/NOTIFY. Any writer (backend or
// the import script) sends NOTIFY 'rtdb_change'; every backend instance hears
// it and refreshes the affected realtime subscriptions.
const changes = new EventEmitter();
changes.setMaxListeners(0);

const CHANNEL = "rtdb_change";

async function startListener() {
  const client = new Client({ connectionString });
  client.on("error", (err) => {
    console.error("[db] listener error, reconnecting:", err.message);
    setTimeout(() => startListener().catch(() => {}), 2000);
  });
  await client.connect();
  await client.query(`LISTEN ${CHANNEL}`);
  client.on("notification", (msg) => {
    if (msg.channel !== CHANNEL || !msg.payload) return;
    try {
      changes.emit("change", JSON.parse(msg.payload));
    } catch (_) {
      /* ignore malformed */
    }
  });
  console.log("[db] listening for realtime changes");
}

// Send a change notification. `paths` is the list of leaf-path roots touched.
async function notifyChange(executor, dbName, paths) {
  const payload = JSON.stringify({ db: dbName, paths });
  // NOTIFY payload cap is ~8000 bytes; if huge, send a wildcard refresh.
  const safe = payload.length < 7500 ? payload : JSON.stringify({ db: dbName, paths: ["*"] });
  await executor.query(`SELECT pg_notify($1, $2)`, [CHANNEL, safe]);
}

module.exports = { pool, changes, startListener, notifyChange };
