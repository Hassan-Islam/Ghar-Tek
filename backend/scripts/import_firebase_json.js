#!/usr/bin/env node
// Imports a Firebase Realtime Database JSON export into Postgres, preserving
// every value. Flattens the exported tree to leaf rows exactly the way the
// backend stores live data, so the app sees identical data afterwards.
//
// Usage:
//   node scripts/import_firebase_json.js                      (auto: data/*.json)
//   node scripts/import_firebase_json.js --file data/main.json --db main --truncate
//
// Convention for auto mode (put your Console exports here):
//   backend/data/main.json     -> pak-delivers export     -> db_name 'main'
//   backend/data/ratings.json  -> ghartek-c3399 export    -> db_name 'ratings'

const fs = require("fs");
const path = require("path");
const { Pool } = require("pg");
const { flattenLeaves } = require("../src/tree");

const connectionString =
  process.env.DATABASE_URL ||
  "postgres://ghartek:ghartek_local_pw@localhost:5433/ghartek";

function parseArgs(argv) {
  const args = { truncate: false };
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--file") args.file = argv[++i];
    else if (a === "--db") args.db = argv[++i];
    else if (a === "--truncate") args.truncate = true;
  }
  return args;
}

async function importFile(pool, filePath, dbName, truncate) {
  const abs = path.resolve(filePath);
  if (!fs.existsSync(abs)) {
    console.log(`[import] skip (not found): ${filePath}`);
    return;
  }
  console.log(`[import] reading ${filePath} -> db '${dbName}'`);
  const root = JSON.parse(fs.readFileSync(abs, "utf8"));
  const leaves = flattenLeaves("", root);
  console.log(`[import] ${leaves.length} leaf values`);

  const client = await pool.connect();
  try {
    await client.query("BEGIN");
    if (truncate) {
      await client.query(`DELETE FROM rtdb_nodes WHERE db_name = $1`, [dbName]);
      console.log(`[import] cleared existing '${dbName}' rows`);
    }
    const CHUNK = 1000;
    for (let i = 0; i < leaves.length; i += CHUNK) {
      const slice = leaves.slice(i, i + CHUNK);
      const paths = slice.map((l) => l[0]);
      const values = slice.map((l) => JSON.stringify(l[1]));
      await client.query(
        `INSERT INTO rtdb_nodes (db_name, path, value, updated_at)
           SELECT $1, p, v::jsonb, now()
             FROM unnest($2::text[], $3::text[]) AS t(p, v)
         ON CONFLICT (db_name, path)
           DO UPDATE SET value = EXCLUDED.value, updated_at = now()`,
        [dbName, paths, values]
      );
      process.stdout.write(`\r[import] ${Math.min(i + CHUNK, leaves.length)}/${leaves.length}`);
    }
    process.stdout.write("\n");
    await client.query("COMMIT");
    console.log(`[import] done: '${dbName}'`);
  } catch (e) {
    await client.query("ROLLBACK");
    throw e;
  } finally {
    client.release();
  }
}

async function main() {
  const args = parseArgs(process.argv);
  const pool = new Pool({ connectionString });
  try {
    if (args.file) {
      await importFile(pool, args.file, args.db || "main", args.truncate);
    } else {
      const dataDir = path.resolve(__dirname, "../data");
      await importFile(pool, path.join(dataDir, "main.json"), "main", args.truncate);
      await importFile(pool, path.join(dataDir, "ratings.json"), "ratings", args.truncate);
    }
  } finally {
    await pool.end();
  }
}

main().catch((e) => {
  console.error("[import] failed:", e);
  process.exit(1);
});
