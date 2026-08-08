#!/usr/bin/env node
// Pulls the LIVE Firebase Realtime Database into PostgreSQL (one-time migration).
//
// Prerequisites:
//   1. Firebase Console -> Project Settings -> Service Accounts -> Generate key
//   2. Save as backend/secrets/serviceAccountKey.json
//   3. Postgres running: cd backend && docker compose up -d
//
// Usage:
//   cd backend && npm run sync:firebase

const fs = require("fs");
const path = require("path");
const admin = require("firebase-admin");
const { Pool } = require("pg");
const { flattenLeaves } = require("../src/tree");

const connectionString =
  process.env.DATABASE_URL ||
  "postgres://ghartek:ghartek_local_pw@localhost:5433/ghartek";

const credPath =
  process.env.GOOGLE_APPLICATION_CREDENTIALS ||
  path.resolve(__dirname, "../secrets/serviceAccountKey.json");

async function importTree(pool, dbName, root, label) {
  if (!root || typeof root !== "object") {
    console.log(`[sync] skip empty ${label}`);
    return 0;
  }
  const leaves = flattenLeaves("", root);
  console.log(`[sync] ${label}: ${leaves.length} leaf values`);
  const client = await pool.connect();
  try {
    await client.query("BEGIN");
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
    }
    await client.query("COMMIT");
    return leaves.length;
  } catch (e) {
    await client.query("ROLLBACK");
    throw e;
  } finally {
    client.release();
  }
}

async function main() {
  if (!fs.existsSync(credPath)) {
    console.error(
      "[sync] Missing service account key at:",
      credPath,
      "\nDownload from Firebase Console -> Project Settings -> Service Accounts"
    );
    process.exit(1);
  }

  const serviceAccount = require(credPath);
  admin.initializeApp({
    credential: admin.credential.cert(serviceAccount),
    databaseURL:
      process.env.FIREBASE_DATABASE_URL ||
      "https://pak-delivers-default-rtdb.firebaseio.com",
  });

  const mainDb = admin.database();
  console.log("[sync] downloading pak-delivers (main)...");
  const mainSnap = await mainDb.ref("/").once("value");
  const mainData = mainSnap.val();

  // Ratings database (secondary Firebase project).
  let ratingsData = null;
  try {
    const ratingsApp = admin.initializeApp(
      {
        credential: admin.credential.cert(serviceAccount),
        databaseURL: "https://ghartek-c3399-default-rtdb.firebaseio.com",
      },
      "ratingsSync"
    );
    console.log("[sync] downloading ghartek-c3399 (ratings)...");
    const ratingsSnap = await ratingsApp.database().ref("/").once("value");
    ratingsData = ratingsSnap.val();
  } catch (e) {
    console.warn("[sync] ratings DB skipped:", e.message);
  }

  const pool = new Pool({ connectionString });
  try {
    const mainCount = await importTree(pool, "main", mainData, "main");
    let ratingsCount = 0;
    if (ratingsData) {
      ratingsCount = await importTree(pool, "ratings", ratingsData, "ratings");
    }
    const { rows } = await pool.query(
      "SELECT count(*)::int AS n FROM rtdb_nodes"
    );
    console.log(
      `[sync] done. imported main=${mainCount} ratings=${ratingsCount} total_rows=${rows[0].n}`
    );
  } finally {
    await pool.end();
  }
}

main().catch((e) => {
  console.error("[sync] failed:", e);
  process.exit(1);
});
