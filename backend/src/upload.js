const crypto = require("crypto");
const express = require("express");
const multer = require("multer");
const { S3Client, PutObjectCommand } = require("@aws-sdk/client-s3");

// DigitalOcean Spaces (S3-compatible) image storage. Replaces Cloudinary.
const REGION = process.env.SPACES_REGION || "sfo3";
const BUCKET = process.env.SPACES_BUCKET || "ghartek-media";
const ENDPOINT =
  process.env.SPACES_ENDPOINT || `https://${REGION}.digitaloceanspaces.com`;
const KEY = process.env.SPACES_KEY || "";
const SECRET = process.env.SPACES_SECRET || "";
const AUTH_DISABLED = process.env.AUTH_DISABLED === "1";

const enabled = Boolean(KEY && SECRET);

// Public origin URL for objects (per-object ACL is public-read).
// e.g. https://ghartek-media.blr1.digitaloceanspaces.com/<key>
const PUBLIC_BASE = ENDPOINT.replace("https://", `https://${BUCKET}.`);

const s3 = enabled
  ? new S3Client({
      region: REGION,
      endpoint: ENDPOINT,
      forcePathStyle: false,
      credentials: { accessKeyId: KEY, secretAccessKey: SECRET },
    })
  : null;

const MIME_BY_EXT = {
  jpg: "image/jpeg",
  jpeg: "image/jpeg",
  png: "image/png",
  webp: "image/webp",
  heic: "image/heic",
  heif: "image/heif",
  gif: "image/gif",
  bmp: "image/bmp",
};

const FOLDER_BY_USECASE = {
  profile: "ghartek/profiles",
  product: "ghartek/products",
  shop: "ghartek/shops",
  ad: "ghartek/ads",
};

const upload = multer({
  storage: multer.memoryStorage(),
  limits: { fileSize: 8 * 1024 * 1024 }, // 8MB, matches the app-side cap
});

function extFromName(name) {
  const parts = String(name || "").toLowerCase().split(".");
  return parts.length > 1 ? parts.pop() : "";
}

const router = express.Router();

router.post("/v1/upload", upload.single("file"), async (req, res) => {
  try {
    if (!enabled) {
      return res
        .status(503)
        .json({ error: "Image storage not configured (SPACES_KEY missing)." });
    }
    if (!AUTH_DISABLED && !req.uid) {
      return res.status(401).json({ error: "Login required to upload images." });
    }
    if (!req.file || !req.file.buffer || req.file.buffer.length === 0) {
      return res.status(400).json({ error: "No image file received." });
    }

    const useCaseRaw = String(req.body.useCase || "product").toLowerCase();
    const useCase = FOLDER_BY_USECASE[useCaseRaw] ? useCaseRaw : "product";
    const folder = FOLDER_BY_USECASE[useCase];

    const ext = extFromName(req.file.originalname) || "jpg";
    const contentType =
      MIME_BY_EXT[ext] || req.file.mimetype || "application/octet-stream";
    if (!MIME_BY_EXT[ext] && !String(contentType).startsWith("image/")) {
      return res.status(400).json({ error: `Unsupported image format: ${ext}` });
    }

    const rand = crypto.randomBytes(6).toString("hex");
    const fileName = `${useCase}_${Date.now()}_${rand}`;
    const key = `${folder}/${fileName}.${ext}`;

    await s3.send(
      new PutObjectCommand({
        Bucket: BUCKET,
        Key: key,
        Body: req.file.buffer,
        ContentType: contentType,
        ACL: "public-read",
        CacheControl: "public, max-age=31536000",
      })
    );

    const url = `${PUBLIC_BASE}/${key}`;
    return res.json({
      url,
      secureUrl: url,
      thumbnailUrl: url,
      fileId: key,
      fileName: `${fileName}.${ext}`,
    });
  } catch (e) {
    console.error("[upload]", e.message);
    return res.status(500).json({ error: e.message || "Upload failed." });
  }
});

module.exports = { uploadRouter: router, spacesEnabled: enabled, spacesBucket: BUCKET };
