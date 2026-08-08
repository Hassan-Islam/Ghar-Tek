const http = require("http");
const express = require("express");
const cors = require("cors");

const { startListener, changes } = require("./db");
const rtdb = require("./rtdb");
const { attachWebSocket } = require("./realtime");
const { dispatchForChangedPaths } = require("./fcm");
const firebase = require("./firebase");
const { uploadRouter, spacesEnabled, spacesBucket } = require("./upload");

const PORT = parseInt(process.env.PORT || "8080", 10);
const AUTH_DISABLED = process.env.AUTH_DISABLED === "1";

const app = express();
app.use(cors());
app.use(express.json({ limit: "10mb" }));

// Optional auth: if the app sends a Firebase ID token we decode it and attach
// req.uid. We don't hard-reject anonymous calls because several screens (city
// selection, splash settings) read before login, matching the old permissive
// RTDB rules. Flip AUTH behaviour here later if you want to tighten it.
app.use(async (req, res, next) => {
  if (AUTH_DISABLED) return next();
  const header = req.headers.authorization || "";
  const token = header.startsWith("Bearer ") ? header.slice(7) : "";
  if (!token) return next();
  try {
    const decoded = await firebase.verifyIdToken(token);
    req.uid = decoded.uid;
    req.userEmail = decoded.email;
  } catch (e) {
    // Invalid token: continue as anonymous rather than break the app.
  }
  next();
});

app.get("/health", (_req, res) =>
  res.json({ ok: true, service: "ghartek-backend", spaces: spacesEnabled })
);

// Image uploads -> DigitalOcean Spaces (multipart/form-data, field "file").
app.use(uploadRouter);

function wrap(fn) {
  return async (req, res) => {
    try {
      const result = await fn(req.body || {});
      res.json(result);
    } catch (e) {
      console.error("[api]", req.path, e.message);
      res.status(500).json({ error: e.message });
    }
  };
}

app.post("/v1/get", wrap(async (b) => ({ value: await rtdb.getValue(b.db || "main", b.path) })));
app.post("/v1/get-shallow", wrap(async (b) => ({
  value: await rtdb.getValueShallow(b.db || "main", b.path),
})));
app.post("/v1/set", wrap(async (b) => { await rtdb.setValue(b.db || "main", b.path, b.value); return { ok: true }; }));
app.post("/v1/update", wrap(async (b) => { await rtdb.updateValue(b.db || "main", b.path, b.value); return { ok: true }; }));
app.post("/v1/push", wrap(async (b) => ({ key: await rtdb.pushValue(b.db || "main", b.path, b.value) })));
app.post("/v1/remove", wrap(async (b) => { await rtdb.removeValue(b.db || "main", b.path); return { ok: true }; }));
app.post("/v1/query", wrap(async (b) => rtdb.queryChildren(b.db || "main", b.path, b.query || {})));
app.post("/v1/queue-stats", wrap(async (b) =>
  rtdb.getQueueStats(b.db || "main", b.path, b.userId || "")
));
app.post("/v1/cas", wrap(async (b) => rtdb.compareAndSet(b.db || "main", b.path, b.expected, b.value)));

const server = http.createServer(app);
attachWebSocket(server);

// New notifications must still fire FCM (the old Cloud Functions job).
changes.on("change", ({ paths }) => {
  dispatchForChangedPaths(paths || []).catch((e) =>
    console.error("[fcm] dispatch error:", e.message)
  );
});

async function main() {
  firebase.init();
  await startListener();
  server.listen(PORT, () => {
    console.log(`[server] GharTek backend on http://localhost:${PORT}`);
    console.log(`[server] WebSocket on ws://localhost:${PORT}/rtdb`);
  });
}

main().catch((e) => {
  console.error("[server] fatal:", e);
  process.exit(1);
});
