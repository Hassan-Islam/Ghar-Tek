#!/usr/bin/env node
/**
 * Copy Cloudinary image URLs in PostgreSQL (rtdb_nodes) to DigitalOcean Spaces
 * and rewrite the stored URLs. Schema is unchanged — only leaf values update.
 *
 * Run on the droplet (reads .env for DB + Spaces creds):
 *   cd /opt/ghartek-backend
 *   node scripts/migrate_cloudinary_to_spaces.js --dry-run
 *   node scripts/migrate_cloudinary_to_spaces.js
 *
 * Options:
 *   --dry-run     List what would migrate; no downloads/uploads/DB writes
 *   --limit=N     Process at most N unique image URLs (default: all)
 */
const crypto = require("crypto");
const { S3Client, PutObjectCommand } = require("@aws-sdk/client-s3");
const { pool, notifyChange } = require("../src/db");

const DRY_RUN = process.argv.includes("--dry-run");
const limitArg = process.argv.find((a) => a.startsWith("--limit="));
const LIMIT = limitArg ? parseInt(limitArg.split("=")[1], 10) : 0;

const REGION = process.env.SPACES_REGION || "sfo3";
const BUCKET = process.env.SPACES_BUCKET || "ghartek-media";
const ENDPOINT =
  process.env.SPACES_ENDPOINT || `https://${REGION}.digitaloceanspaces.com`;
const KEY = process.env.SPACES_KEY || "";
const SECRET = process.env.SPACES_SECRET || "";
const PUBLIC_BASE = ENDPOINT.replace("https://", `https://${BUCKET}.`);

const CLD_CLOUD = process.env.CLOUDINARY_CLOUD_NAME || "dkny5hr1x";
const CLD_KEY = process.env.CLOUDINARY_API_KEY || "";
const CLD_SECRET = process.env.CLOUDINARY_API_SECRET || "";

const CLOUDINARY_RE =
  /https?:\/\/res\.cloudinary\.com\/[a-zA-Z0-9_./%-]+/gi;

/** Extract Cloudinary public_id from a delivery URL. */
function publicIdFromUrl(url) {
  const m = url.match(
    /res\.cloudinary\.com\/[^/]+\/image\/upload\/(?:v\d+\/)?(.+)$/i
  );
  if (!m) return null;
  return m[1].replace(/\.(jpe?g|png|webp|gif)$/i, "");
}

/** Signed Admin API download (works when API keys are set). */
function signedDownloadUrl(publicId) {
  if (!CLD_KEY || !CLD_SECRET || !publicId) return null;
  const timestamp = Math.floor(Date.now() / 1000);
  const toSign = `public_id=${publicId}&timestamp=${timestamp}${CLD_SECRET}`;
  const signature = crypto.createHash("sha1").update(toSign).digest("hex");
  return (
    `https://api.cloudinary.com/v1_1/${CLD_CLOUD}/image/download` +
    `?public_id=${encodeURIComponent(publicId)}` +
    `&timestamp=${timestamp}&api_key=${CLD_KEY}&signature=${signature}`
  );
}

const FOLDER_BY_HINT = {
  shop: "ghartek/shops",
  product: "ghartek/products",
  profile: "ghartek/profiles",
  ad: "ghartek/ads",
};

function guessFolder(dbPath, url) {
  const p = dbPath.toLowerCase();
  const u = url.toLowerCase();
  if (p.includes("/shops/") && (p.endsWith("/imageurl") || p.endsWith("/image")))
    return FOLDER_BY_HINT.shop;
  if (p.includes("/menu/") || p.includes("/products/") || u.includes("/products/"))
    return FOLDER_BY_HINT.product;
  if (p.includes("/ads/") || p.includes("startuppopup") || p.includes("/ad"))
    return FOLDER_BY_HINT.ad;
  if (p.includes("/users/") || p.includes("profile") || p.includes("avatar"))
    return FOLDER_BY_HINT.profile;
  if (u.includes("/shops/")) return FOLDER_BY_HINT.shop;
  return "ghartek/migrated";
}

function extFromContentType(ct, url) {
  const lower = (ct || "").toLowerCase();
  if (lower.includes("png")) return "png";
  if (lower.includes("webp")) return "webp";
  if (lower.includes("gif")) return "gif";
  const m = url.match(/\.(jpe?g|png|webp|gif)(?:\?|$)/i);
  if (m) return m[1].toLowerCase().replace("jpeg", "jpg");
  return "jpg";
}

function collectUrls(value, out) {
  if (value == null) return;
  if (typeof value === "string") {
    const matches = value.match(CLOUDINARY_RE);
    if (matches) matches.forEach((u) => out.add(u));
    return;
  }
  if (typeof value === "object") {
    if (Array.isArray(value)) {
      value.forEach((v) => collectUrls(v, out));
    } else {
      Object.values(value).forEach((v) => collectUrls(v, out));
    }
  }
}

function replaceUrlsInValue(value, urlMap) {
  if (value == null) return value;
  if (typeof value === "string") {
    let next = value;
    for (const [oldU, newU] of urlMap) {
      if (next.includes(oldU)) next = next.split(oldU).join(newU);
    }
    return next;
  }
  if (Array.isArray(value)) {
    return value.map((v) => replaceUrlsInValue(v, urlMap));
  }
  if (typeof value === "object") {
    const out = {};
    for (const [k, v] of Object.entries(value)) {
      out[k] = replaceUrlsInValue(v, urlMap);
    }
    return out;
  }
  return value;
}

async function downloadImage(url) {
  const tryFetch = async (fetchUrl) => {
    const res = await fetch(fetchUrl, {
      redirect: "follow",
      headers: { "User-Agent": "GharTek-Migration/1.0" },
    });
    if (!res.ok) {
      throw new Error(`download HTTP ${res.status}`);
    }
    const buf = Buffer.from(await res.arrayBuffer());
    if (buf.length === 0) throw new Error("empty image");
    if (buf.length > 8 * 1024 * 1024) throw new Error("image exceeds 8MB");
    return {
      buf,
      contentType: res.headers.get("content-type") || "image/jpeg",
    };
  };

  try {
    return await tryFetch(url);
  } catch (publicErr) {
    const publicId = publicIdFromUrl(url);
    const signed = signedDownloadUrl(publicId);
    if (!signed) throw publicErr;
    try {
      return await tryFetch(signed);
    } catch (signedErr) {
      throw new Error(
        `public: ${publicErr.message}; signed: ${signedErr.message}`
      );
    }
  }
}

async function main() {
  if (!KEY || !SECRET) {
    console.error("SPACES_KEY / SPACES_SECRET missing. Set in .env first.");
    process.exit(1);
  }

  const s3 = new S3Client({
    region: REGION,
    endpoint: ENDPOINT,
    forcePathStyle: false,
    credentials: { accessKeyId: KEY, secretAccessKey: SECRET },
  });

  console.log(
    `[migrate] mode=${DRY_RUN ? "DRY-RUN" : "LIVE"} bucket=${BUCKET} region=${REGION} cloudinary_api=${CLD_KEY ? "yes" : "no"}`
  );

  const { rows } = await pool.query(
    `SELECT db_name, path, value
       FROM rtdb_nodes
      WHERE value::text ILIKE '%cloudinary.com%'`
  );

  const uniqueUrls = new Set();
  for (const row of rows) {
    collectUrls(row.value, uniqueUrls);
  }

  console.log(
    `[migrate] ${rows.length} DB rows contain Cloudinary URLs; ${uniqueUrls.size} unique images`
  );

  const urlMap = new Map();
  const failures = [];
  let processed = 0;

  for (const oldUrl of uniqueUrls) {
    if (LIMIT > 0 && processed >= LIMIT) break;

    if (DRY_RUN) {
      console.log(`[dry-run] would copy: ${oldUrl}`);
      urlMap.set(
        oldUrl,
        `${PUBLIC_BASE}/ghartek/migrated/example_${processed}.jpg`
      );
      processed++;
      continue;
    }

    try {
      const samplePath =
        rows.find((r) => JSON.stringify(r.value).includes(oldUrl))?.path || "";
      const folder = guessFolder(samplePath, oldUrl);
      const { buf, contentType } = await downloadImage(oldUrl);
      const ext = extFromContentType(contentType, oldUrl);
      const rand = crypto.randomBytes(6).toString("hex");
      const key = `${folder}/migrated_${Date.now()}_${rand}.${ext}`;

      await s3.send(
        new PutObjectCommand({
          Bucket: BUCKET,
          Key: key,
          Body: buf,
          ACL: "public-read",
          ContentType: contentType,
          CacheControl: "public, max-age=31536000",
        })
      );

      const newUrl = `${PUBLIC_BASE}/${key}`;
      urlMap.set(oldUrl, newUrl);
      processed++;
      console.log(`[ok ${processed}/${uniqueUrls.size}] ${newUrl}`);
    } catch (e) {
      failures.push({ url: oldUrl, error: e.message });
      console.error(`[fail] ${oldUrl} — ${e.message}`);
    }
  }

  if (DRY_RUN) {
    console.log(`[migrate] dry-run complete. Would migrate ${processed} images.`);
    await pool.end();
    return;
  }

  if (urlMap.size === 0) {
    console.log("[migrate] nothing uploaded — DB not modified.");
    if (failures.length) {
      console.log(
        `[migrate] ${failures.length} downloads failed (Cloudinary limit/account issue?).`
      );
    }
    await pool.end();
    return;
  }

  const client = await pool.connect();
  let updatedRows = 0;
  const touchedPaths = [];
  try {
    await client.query("BEGIN");
    for (const row of rows) {
      const before = JSON.stringify(row.value);
      const nextValue = replaceUrlsInValue(row.value, urlMap);
      const after = JSON.stringify(nextValue);
      if (before === after) continue;

      await client.query(
        `UPDATE rtdb_nodes
            SET value = $3::jsonb, updated_at = now()
          WHERE db_name = $1 AND path = $2`,
        [row.db_name, row.path, JSON.stringify(nextValue)]
      );
      updatedRows++;
      touchedPaths.push(row.path);
    }
    await notifyChange(client, "main", touchedPaths.slice(0, 100));
    await client.query("COMMIT");
  } catch (e) {
    await client.query("ROLLBACK");
    throw e;
  } finally {
    client.release();
  }

  console.log(`[migrate] done. uploaded=${urlMap.size} db_rows_updated=${updatedRows}`);
  if (failures.length) {
    console.log(`[migrate] ${failures.length} images could not be copied:`);
    failures.slice(0, 10).forEach((f) => console.log(`  - ${f.url}: ${f.error}`));
    if (failures.length > 10) {
      console.log(`  ... and ${failures.length - 10} more`);
    }
  }

  await pool.end();
}

main().catch((e) => {
  console.error("[migrate] fatal:", e);
  process.exit(1);
});
