// Port of the old Cloud Functions push logic (functions/index.js). Previously
// RTDB onCreate triggers fired these; now the backend calls dispatchForPath()
// whenever a notification record is written to Postgres.

const { getValue, updateValue } = require("./rtdb");
const { messaging } = require("./firebase");

const DEFAULT_CITY = "vehari";
const INVALID_TOKEN_ERRORS = new Set([
  "messaging/registration-token-not-registered",
  "messaging/invalid-registration-token",
]);

function asString(v) {
  if (v === null || v === undefined) return "";
  return String(v).trim();
}
function asMap(v) {
  if (!v || typeof v !== "object" || Array.isArray(v)) return {};
  return v;
}
function normalizeCity(v) {
  const s = asString(v).toLowerCase();
  if (s === "islamabad" || s === "isb" || s === "islamabad_city") return "islamabad";
  if (s === "vehari") return "vehari";
  return DEFAULT_CITY;
}

function addTokensFromUser({ tokens, userData, roleFilter, cityFilter }) {
  const user = asMap(userData);
  const userRole = asString(user.role).toLowerCase() || "customer";
  const fallbackCity = normalizeCity(userRole === "admin" ? user.adminCity : user.userCity);
  const tokenEntries = asMap(user.fcmTokens);
  for (const value of Object.values(tokenEntries)) {
    const row = typeof value === "string" ? { token: value } : asMap(value);
    const token = asString(row.token);
    if (!token) continue;
    const tokenRole = asString(row.role || userRole).toLowerCase() || userRole;
    const tokenCity = normalizeCity(row.city || fallbackCity);
    if (roleFilter && tokenRole !== roleFilter) continue;
    if (cityFilter && tokenCity !== cityFilter) continue;
    tokens.add(token);
  }
}

async function collectTokens({ userId = "", role = "", city = "" }) {
  const roleFilter = asString(role).toLowerCase();
  const cityFilter = city ? normalizeCity(city) : "";
  const tokens = new Set();

  if (userId) {
    const user = await getValue("main", `users/${userId}`);
    if (user) addTokensFromUser({ tokens, userData: user, roleFilter, cityFilter });
    return Array.from(tokens);
  }

  const users = asMap(await getValue("main", "users"));
  for (const userData of Object.values(users)) {
    addTokensFromUser({ tokens, userData, roleFilter, cityFilter });
  }
  return Array.from(tokens);
}

async function cleanupInvalidTokensForUser(userId, invalidTokens) {
  if (!userId || invalidTokens.length === 0) return;
  const tokenMap = asMap(await getValue("main", `users/${userId}/fcmTokens`));
  const updates = {};
  for (const [key, value] of Object.entries(tokenMap)) {
    const row = typeof value === "string" ? { token: value } : asMap(value);
    if (invalidTokens.includes(asString(row.token))) updates[key] = null;
  }
  if (Object.keys(updates).length > 0) {
    await updateValue("main", `users/${userId}/fcmTokens`, updates);
  }
}

async function sendToTokens({ tokens, title, body, data, userIdForCleanup = "" }) {
  const fcm = messaging();
  if (!fcm) {
    console.warn("[fcm] no service account; skipping push:", title);
    return { successCount: 0, failureCount: 0, invalidTokens: [] };
  }
  if (!tokens || tokens.length === 0) {
    return { successCount: 0, failureCount: 0, invalidTokens: [] };
  }
  const response = await fcm.sendEachForMulticast({
    tokens,
    notification: { title, body },
    data,
    android: { priority: "high", notification: { channelId: "ghartek_main", sound: "default" } },
    apns: { headers: { "apns-priority": "10" }, payload: { aps: { sound: "default" } } },
  });
  const invalidTokens = [];
  response.responses.forEach((r, i) => {
    const code = r.error && r.error.code ? r.error.code : "";
    if (INVALID_TOKEN_ERRORS.has(code)) invalidTokens.push(tokens[i]);
  });
  if (userIdForCleanup && invalidTokens.length > 0) {
    await cleanupInvalidTokensForUser(userIdForCleanup, invalidTokens);
  }
  return { successCount: response.successCount, failureCount: response.failureCount, invalidTokens };
}

function buildDataPayload(obj) {
  const data = {};
  for (const [k, v] of Object.entries(obj)) {
    const t = asString(v);
    if (t) data[k] = t;
  }
  return data;
}

async function markDelivery(rootPath, payload) {
  await updateValue("main", `${rootPath}/_delivery`, {
    ...payload,
    sentAt: Date.now(),
  });
}

// Match a notification record path and return routing info, or null.
// Handles both tenant-scoped and legacy paths.
function parseNotificationPath(path) {
  let m;
  // tenants/{city}/notifications/...
  m = path.match(/^tenants\/([^/]+)\/notifications\/(.+)$/);
  const city = m ? m[1] : "";
  const rest = m ? m[2] : path.match(/^notifications\/(.+)$/)?.[1];
  if (!rest) return null;

  let mm;
  if ((mm = rest.match(/^user\/([^/]+)\/([^/]+)$/))) {
    return { channel: "user", city, userId: mm[1], notifId: mm[2] };
  }
  if ((mm = rest.match(/^merchant\/([^/]+)\/([^/]+)$/))) {
    return { channel: "merchant", city, userId: mm[1], notifId: mm[2] };
  }
  if ((mm = rest.match(/^admin\/inbox\/([^/]+)$/))) {
    return { channel: "admin", city, role: "admin", notifId: mm[1] };
  }
  if ((mm = rest.match(/^rider\/inbox\/([^/]+)$/))) {
    return { channel: "rider", city, role: "rider", notifId: mm[1] };
  }
  if ((mm = rest.match(/^broadcast\/([^/]+)$/))) {
    return { channel: "broadcast", city, notifId: mm[1] };
  }
  return null;
}

// Given ANY changed leaf path, work out the notification record root.
function notificationRootFromLeaf(leafPath) {
  const patterns = [
    /^((?:tenants\/[^/]+\/)?notifications\/user\/[^/]+\/[^/]+)/,
    /^((?:tenants\/[^/]+\/)?notifications\/merchant\/[^/]+\/[^/]+)/,
    /^((?:tenants\/[^/]+\/)?notifications\/admin\/inbox\/[^/]+)/,
    /^((?:tenants\/[^/]+\/)?notifications\/rider\/inbox\/[^/]+)/,
    /^((?:tenants\/[^/]+\/)?notifications\/broadcast\/[^/]+)/,
  ];
  for (const re of patterns) {
    const m = leafPath.match(re);
    if (m) return m[1];
  }
  return null;
}

async function dispatchForRoot(rootPath) {
  const info = parseNotificationPath(rootPath);
  if (!info) return;
  const record = asMap(await getValue("main", rootPath));
  if (!record || Object.keys(record).length === 0) return;
  if (record._delivery) return; // already handled

  const cityValue = info.city ? normalizeCity(info.city) : normalizeCity(record.city);
  const title = asString(record.title) || defaultTitle(info.channel);
  const body = asString(record.body) || defaultBody(info.channel);

  let tokens = [];
  let userIdForCleanup = "";
  if (info.channel === "user" || info.channel === "merchant") {
    tokens = await collectTokens({ userId: info.userId });
    userIdForCleanup = info.userId;
  } else if (info.channel === "admin" || info.channel === "rider") {
    if (!info.city && !record.city) {
      await markDelivery(rootPath, { channel: `${info.role}_inbox`, error: "missing_city" });
      return;
    }
    tokens = await collectTokens({ role: info.role, city: cityValue });
  } else if (info.channel === "broadcast") {
    if (!info.city && !record.city) {
      await markDelivery(rootPath, { channel: "broadcast", error: "missing_city" });
      return;
    }
    tokens = await collectTokens({ city: cityValue });
  }

  const data = buildDataPayload({
    type: asString(record.type) || `${info.channel}_notification`,
    city: cityValue,
    notificationId: info.notifId,
    orderId: record.orderId || asMap(record.details).orderId,
    source: "backend_notifications",
    targetUserId: info.userId || "",
  });

  const result = await sendToTokens({ tokens, title, body, data, userIdForCleanup });
  await markDelivery(rootPath, {
    channel: info.channel,
    city: cityValue,
    tokensTried: tokens.length,
    successCount: result.successCount,
    failureCount: result.failureCount,
  });
}

function defaultTitle(channel) {
  if (channel === "admin") return "New Order";
  if (channel === "rider") return "New Delivery Task";
  if (channel === "broadcast") return "GharTek Announcement";
  return "Order Update";
}
function defaultBody(channel) {
  if (channel === "admin") return "A new order has been received.";
  if (channel === "rider") return "A delivery order is ready for pickup.";
  if (channel === "broadcast") return "You have a new announcement.";
  return "You have a new update from GharTek.";
}

// Called from the change stream. Dedupes so each notification fires once.
const seen = new Set();
async function dispatchForChangedPaths(paths) {
  const roots = new Set();
  for (const p of paths) {
    if (p === "*") continue;
    const root = notificationRootFromLeaf(p);
    if (root && !root.endsWith("/_delivery")) roots.add(root);
  }
  for (const root of roots) {
    if (seen.has(root)) continue;
    seen.add(root);
    if (seen.size > 5000) seen.clear();
    try {
      await dispatchForRoot(root);
    } catch (e) {
      console.error("[fcm] dispatch failed for", root, e.message);
    }
  }
}

module.exports = { dispatchForChangedPaths };
