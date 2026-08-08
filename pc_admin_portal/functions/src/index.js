const functions = require("firebase-functions");
const admin = require("firebase-admin");
const axios = require("axios");

// Initialize Firebase Admin SDK
admin.initializeApp();

const cloudName = process.env.CLOUDINARY_CLOUD_NAME;
const uploadPreset = process.env.CLOUDINARY_UPLOAD_PRESET;

if (!cloudName || !uploadPreset) {
  console.error("Cloudinary environment variables not configured!");
  console.error("CLOUDINARY_CLOUD_NAME:", cloudName ? "SET" : "MISSING");
  console.error("CLOUDINARY_UPLOAD_PRESET:", uploadPreset ? "SET" : "MISSING");
}

function normalizeBase64(raw) {
  const clean = String(raw || "").trim();
  if (!clean) return "";
  if (clean.startsWith("data:")) {
    const commaIndex = clean.indexOf(",");
    if (commaIndex === -1) return "";
    return clean.slice(commaIndex + 1).replace(/\s/g, "");
  }
  return clean.replace(/\s/g, "");
}

function resolveFolder(useCase) {
  const key = String(useCase || "product").toLowerCase();
  if (key === "profile") return "ghartek/profiles";
  if (key === "shop") return "ghartek/shops";
  if (key === "ad") return "ghartek/ads";
  return "ghartek/products";
}

function inferMimeType(fileName) {
  const ext = String(fileName || "")
    .split(".")
    .pop()
    ?.toLowerCase();
  if (ext === "png") return "image/png";
  if (ext === "webp") return "image/webp";
  if (ext === "gif") return "image/gif";
  if (ext === "bmp") return "image/bmp";
  if (ext === "heic") return "image/heic";
  if (ext === "heif") return "image/heif";
  return "image/jpeg";
}

exports.uploadImage = functions.https.onCall(async (data, context) => {
  try {
    if (!context.auth) {
      throw new functions.https.HttpsError(
        "unauthenticated",
        "User must be authenticated to upload images.",
      );
    }

    const { file, fileName, useCase } = data || {};

    if (!file || typeof file !== "string") {
      throw new functions.https.HttpsError(
        "invalid-argument",
        "file must be a base64 string",
      );
    }

    if (!fileName || typeof fileName !== "string") {
      throw new functions.https.HttpsError(
        "invalid-argument",
        "fileName must be a string",
      );
    }

    if (!cloudName || !uploadPreset) {
      throw new functions.https.HttpsError(
        "failed-precondition",
        "Cloudinary is not configured. Missing environment variables.",
      );
    }

    const normalizedBase64 = normalizeBase64(file);
    if (!normalizedBase64) {
      throw new functions.https.HttpsError(
        "invalid-argument",
        "Invalid base64 image payload.",
      );
    }

    const fileSizeInBytes = Buffer.from(normalizedBase64, "base64").length;
    const fileSizeInMB = fileSizeInBytes / (1024 * 1024);
    if (fileSizeInMB > 8) {
      throw new functions.https.HttpsError(
        "invalid-argument",
        `File size (${fileSizeInMB.toFixed(2)}MB) exceeds 8MB limit`,
      );
    }

    const folder = resolveFolder(useCase);
    const mimeType = inferMimeType(fileName);
    const publicIdPrefix =
      String(useCase || "product")
        .toLowerCase()
        .replace(/[^a-z0-9-_]+/g, "_") || "product";
    const publicId = `${publicIdPrefix}_${Date.now()}`;

    const uploadUrl = `https://api.cloudinary.com/v1_1/${cloudName}/image/upload`;
    const body = new URLSearchParams();
    body.append("file", `data:${mimeType};base64,${normalizedBase64}`);
    body.append("upload_preset", uploadPreset);
    body.append("folder", folder);
    body.append("public_id", publicId);
    body.append("tags", `ghartek,${publicIdPrefix}`);

    const response = await axios.post(uploadUrl, body.toString(), {
      headers: {
        "Content-Type": "application/x-www-form-urlencoded",
      },
      timeout: 30000,
    });

    const payload = response.data || {};
    const url = payload.secure_url || payload.url;

    if (!url) {
      throw new functions.https.HttpsError(
        "internal",
        "Cloudinary response missing URL.",
      );
    }

    return {
      success: true,
      url,
      thumbnailUrl: url,
      fileId: payload.public_id || publicId,
      fileName: payload.original_filename || fileName,
    };
  } catch (error) {
    console.error("Image upload error:", error.message);
    console.error("Error details:", error.response?.data || error.stack);

    if (error.response?.status === 400) {
      throw new functions.https.HttpsError(
        "invalid-argument",
        error.response?.data?.error?.message ||
          "Cloudinary rejected upload request.",
      );
    }

    if (error.code === "ECONNABORTED") {
      throw new functions.https.HttpsError(
        "deadline-exceeded",
        "Upload timed out. Please try again.",
      );
    }

    if (error instanceof functions.https.HttpsError) {
      throw error;
    }

    throw new functions.https.HttpsError(
      "internal",
      `Upload failed: ${error.message}`,
    );
  }
});

const FCM_BATCH_SIZE = 500;

function asString(value, fallback = "") {
  if (value === undefined || value === null) return fallback;
  return String(value);
}

function normalizeCity(rawCity) {
  const value = asString(rawCity, "vehari").trim().toLowerCase();
  if (value === "islamabad" || value === "isb" || value === "islamabad_city") {
    return "islamabad";
  }
  return "vehari";
}

function normalizeRole(rawRole) {
  return asString(rawRole, "customer").trim().toLowerCase();
}

function toDataMap(rawData = {}) {
  const output = {};
  Object.entries(rawData).forEach(([key, value]) => {
    if (value === undefined || value === null) return;
    output[key] = String(value);
  });
  return output;
}

function chunkArray(items, size) {
  const chunks = [];
  for (let i = 0; i < items.length; i += size) {
    chunks.push(items.slice(i, i + size));
  }
  return chunks;
}

function cityTopic(city) {
  return `city_${normalizeCity(city)}`;
}

function roleTopic(role, city) {
  return `role_${normalizeRole(role)}_${normalizeCity(city)}`;
}

async function getUserTokenEntries(userId) {
  if (!userId) return [];

  const tokensSnap = await admin
    .database()
    .ref(`users/${userId}/fcmTokens`)
    .get();
  if (!tokensSnap.exists()) return [];

  const raw = tokensSnap.val();
  if (!raw || typeof raw !== "object") return [];

  const entries = [];
  Object.entries(raw).forEach(([dbKey, row]) => {
    if (typeof row === "string" && row.trim()) {
      entries.push({ dbKey, token: row.trim() });
      return;
    }

    if (
      row &&
      typeof row === "object" &&
      typeof row.token === "string" &&
      row.token.trim()
    ) {
      entries.push({ dbKey, token: row.token.trim() });
    }
  });

  return entries;
}

function shouldPruneToken(errorCode) {
  return (
    errorCode === "messaging/invalid-registration-token" ||
    errorCode === "messaging/registration-token-not-registered"
  );
}

async function pruneInvalidTokens(userId, tokenEntries, responses) {
  if (!userId || !tokenEntries.length || !responses.length) return;

  const updates = {};
  responses.forEach((res, index) => {
    if (res.success) return;
    const code = res.error?.code || "";
    if (!shouldPruneToken(code)) return;
    const dbKey = tokenEntries[index]?.dbKey;
    if (dbKey) updates[dbKey] = null;
  });

  if (Object.keys(updates).length > 0) {
    await admin.database().ref(`users/${userId}/fcmTokens`).update(updates);
  }
}

function buildNotificationMessage({ title, body, data }) {
  return {
    notification: {
      title: asString(title, "GharTek"),
      body: asString(body),
    },
    data: toDataMap(data),
    android: {
      priority: "high",
      notification: {
        channelId: "ghartek_main",
        sound: "default",
      },
    },
    apns: {
      payload: {
        aps: {
          sound: "default",
        },
      },
    },
  };
}

async function sendToTopic({ topic, title, body, data = {} }) {
  if (!topic) return null;

  const message = {
    topic,
    ...buildNotificationMessage({ title, body, data }),
  };

  return admin.messaging().send(message);
}

async function sendToUserTokens({ userId, title, body, data = {} }) {
  if (!userId) return { sent: 0, failed: 0 };

  const tokenEntries = await getUserTokenEntries(userId);
  if (!tokenEntries.length) return { sent: 0, failed: 0 };

  let sent = 0;
  let failed = 0;

  const tokenChunks = chunkArray(tokenEntries, FCM_BATCH_SIZE);
  for (const chunk of tokenChunks) {
    const tokens = chunk.map((entry) => entry.token);
    const response = await admin.messaging().sendEachForMulticast({
      tokens,
      ...buildNotificationMessage({ title, body, data }),
    });

    sent += response.successCount;
    failed += response.failureCount;

    await pruneInvalidTokens(userId, chunk, response.responses);
  }

  return { sent, failed };
}

function buildOrderStatusNotification(order, status) {
  const safeStatus = asString(status).trim().toLowerCase();
  const shopName = asString(order.shopName || order.shop || "Your order");
  const orderCode = asString(order.customOrderId || "").trim();
  const cancelReason = asString(
    order.cancelReason || order.cancellationReason || "",
  ).trim();

  const orderLabel = orderCode ? `Order ${orderCode}` : "Your order";

  switch (safeStatus) {
    case "merchant_pending":
      return {
        title: "Order Approved by Admin",
        body: `${orderLabel} is waiting for merchant acceptance.`,
      };
    case "confirmed":
      return {
        title: "Order Update",
        body: `${orderLabel} was accepted by merchant and is now confirmed.`,
      };
    case "preparing":
      return {
        title: "Order Update",
        body: `${shopName} is preparing ${orderCode ? `order ${orderCode}` : "your order"}.`,
      };
    case "on_way":
    case "on_the_way":
    case "out_for_delivery":
      return {
        title: "Order Update",
        body: `${orderLabel} is on the way.`,
      };
    case "delivered":
      return {
        title: "Order Delivered",
        body: `${shopName} delivered ${orderCode ? `order ${orderCode}` : "your order"} successfully.`,
      };
    case "canceled":
    case "cancelled":
      return {
        title: "Order Canceled",
        body: cancelReason
          ? `${orderLabel} was canceled: ${cancelReason}`
          : `${orderLabel} from ${shopName} was canceled.`,
      };
    default:
      return null;
  }
}

async function handleOrderStatusChange(change, context, orderType) {
  const after = change.after.val();
  if (!after || typeof after !== "object") return null;

  const before = change.before.exists() ? change.before.val() : null;
  const beforeStatus =
    before && typeof before === "object"
      ? asString(before.status).trim().toLowerCase()
      : "";
  const afterStatus = asString(after.status).trim().toLowerCase();

  if (!afterStatus || afterStatus === beforeStatus) {
    return null;
  }

  const message = buildOrderStatusNotification(after, afterStatus);
  if (!message) return null;

  const userId = asString(after.userId).trim();
  if (!userId) return null;

  const city = normalizeCity(context.params.city);
  await sendToUserTokens({
    userId,
    title: message.title,
    body: message.body,
    data: {
      type: "order_status",
      city,
      status: afterStatus,
      orderId: context.params.orderId,
      orderType,
    },
  });

  return null;
}

exports.onTenantBroadcastNotificationCreated = functions.database
  .ref("/tenants/{city}/notifications/broadcast/{notificationId}")
  .onCreate(async (snapshot, context) => {
    const payload = snapshot.val() || {};
    const city = normalizeCity(context.params.city);
    const title = asString(payload.title, "GharTek");
    const body = asString(payload.body);

    await sendToTopic({
      topic: cityTopic(city),
      title,
      body,
      data: {
        type: "broadcast",
        city,
        notificationId: context.params.notificationId,
      },
    });

    return null;
  });

exports.onTenantAdminInboxNotificationCreated = functions.database
  .ref("/tenants/{city}/notifications/admin/inbox/{notificationId}")
  .onCreate(async (snapshot, context) => {
    const payload = snapshot.val() || {};
    const city = normalizeCity(context.params.city);

    await sendToTopic({
      topic: roleTopic("admin", city),
      title: asString(payload.title, "New Order"),
      body: asString(payload.body, "A new order has arrived."),
      data: {
        type: "admin_order_alert",
        city,
        notificationId: context.params.notificationId,
      },
    });

    return null;
  });

exports.onTenantMerchantInboxNotificationCreated = functions.database
  .ref("/tenants/{city}/notifications/merchant/{merchantId}/{notificationId}")
  .onCreate(async (snapshot, context) => {
    const payload = snapshot.val() || {};
    const city = normalizeCity(context.params.city);
    const merchantId = asString(context.params.merchantId).trim();
    if (!merchantId) return null;

    await sendToUserTokens({
      userId: merchantId,
      title: asString(payload.title, "Order Update"),
      body: asString(payload.body, "You have a new order update."),
      data: {
        type: "merchant_order_alert",
        city,
        notificationId: context.params.notificationId,
      },
    });

    return null;
  });

exports.onTenantUserNotificationCreated = functions.database
  .ref("/tenants/{city}/notifications/user/{userId}/{notificationId}")
  .onCreate(async (snapshot, context) => {
    const payload = snapshot.val() || {};
    const city = normalizeCity(context.params.city);
    const userId = asString(context.params.userId).trim();
    if (!userId) return null;

    await sendToUserTokens({
      userId,
      title: asString(payload.title, "Notification"),
      body: asString(payload.body, "You have a new update."),
      data: {
        type: asString(payload.type || payload.source || "user_direct_push"),
        city,
        notificationId: context.params.notificationId,
      },
    });

    return null;
  });

exports.onTenantShopOrderStatusChanged = functions.database
  .ref("/tenants/{city}/shop-orders/{orderId}")
  .onWrite((change, context) =>
    handleOrderStatusChange(change, context, "shop"),
  );

exports.onTenantCustomOrderStatusChanged = functions.database
  .ref("/tenants/{city}/custom-orders/{orderId}")
  .onWrite((change, context) =>
    handleOrderStatusChange(change, context, "custom"),
  );

const WEEKLY_REWARD_MIN_ORDER = 199;
const WEEKLY_REWARD_PRIZES = [500, 300, 200];
const WEEKLY_REWARD_CITIES = ["vehari", "islamabad"];
const PKT_OFFSET_MS = 5 * 60 * 60 * 1000;
const DAY_MS = 24 * 60 * 60 * 1000;

function asNumber(value, fallback = 0) {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function toEpochMs(raw) {
  if (typeof raw === "number" && Number.isFinite(raw)) {
    return Math.trunc(raw);
  }

  if (typeof raw === "string") {
    const trimmed = raw.trim();
    if (!trimmed) return null;

    const asInt = Number.parseInt(trimmed, 10);
    if (Number.isFinite(asInt)) return asInt;

    const asDate = Date.parse(trimmed);
    if (Number.isFinite(asDate)) return asDate;
  }

  return null;
}

function resolveOrderAmount(order) {
  return asNumber(
    order.grandTotal ?? order.totalAmount ?? order.subtotal ?? order.budget,
    0,
  );
}

function resolveOrderTimestamp(order) {
  return (
    toEpochMs(order.deliveredAt) ??
    toEpochMs(order.updatedAt) ??
    toEpochMs(order.createdAt) ??
    toEpochMs(order.createdAtClient) ??
    toEpochMs(order.timestamp)
  );
}

function isDeliveredStatus(status) {
  const value = asString(status).trim().toLowerCase();
  return value === "delivered" || value === "completed";
}

function displayNameForUser(userId, usersByUid) {
  const row = usersByUid?.[userId];
  if (!row || typeof row !== "object") {
    return userId ? `User ${userId.slice(0, 8)}` : "User";
  }

  const name = asString(row.name).trim();
  if (name) return name;

  const displayName = asString(row.displayName).trim();
  if (displayName) return displayName;

  const email = asString(row.email).trim();
  if (email) return email;

  return userId ? `User ${userId.slice(0, 8)}` : "User";
}

function startOfPkDayShifted(shiftedMs) {
  const date = new Date(shiftedMs);
  return Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), date.getUTCDate());
}

function pad2(value) {
  return String(value).padStart(2, "0");
}

function formatPkDateKey(shiftedMs) {
  const date = new Date(shiftedMs);
  return `${date.getUTCFullYear()}${pad2(date.getUTCMonth() + 1)}${pad2(date.getUTCDate())}`;
}

function formatPkDayMonth(shiftedMs) {
  const date = new Date(shiftedMs);
  return `${pad2(date.getUTCDate())}/${pad2(date.getUTCMonth() + 1)}`;
}

function getWeeklyRewardWindowInPk(nowMs = Date.now()) {
  const shiftedNowMs = nowMs + PKT_OFFSET_MS;
  const shiftedNow = new Date(shiftedNowMs);
  const weekday = shiftedNow.getUTCDay(); // 0 = Sunday

  const todayStartShiftedMs = startOfPkDayShifted(shiftedNowMs);
  const daysSinceMonday = (weekday + 6) % 7;
  const mondayStartShiftedMs = todayStartShiftedMs - daysSinceMonday * DAY_MS;
  const sundayStartShiftedMs = mondayStartShiftedMs + 6 * DAY_MS;
  const nextMondayShiftedMs = mondayStartShiftedMs + 7 * DAY_MS;

  return {
    weekday,
    weekKey: formatPkDateKey(mondayStartShiftedMs),
    weekStartMs: mondayStartShiftedMs - PKT_OFFSET_MS,
    weekEndMs: sundayStartShiftedMs - PKT_OFFSET_MS,
    nextWeekStartMs: nextMondayShiftedMs - PKT_OFFSET_MS,
    windowLabel: `${formatPkDayMonth(mondayStartShiftedMs)} - ${formatPkDayMonth(sundayStartShiftedMs - 1000)}`,
  };
}

function collectEligibleOrders(
  rawOrders,
  countsByUser,
  weekStartMs,
  weekEndMs,
) {
  if (!rawOrders || typeof rawOrders !== "object") return;

  Object.values(rawOrders).forEach((rawOrder) => {
    if (!rawOrder || typeof rawOrder !== "object") return;

    if (!isDeliveredStatus(rawOrder.status)) return;

    const amount = resolveOrderAmount(rawOrder);
    if (amount < WEEKLY_REWARD_MIN_ORDER) return;

    const timestamp = resolveOrderTimestamp(rawOrder);
    if (!Number.isFinite(timestamp)) return;
    if (timestamp < weekStartMs || timestamp >= weekEndMs) return;

    const userId = asString(rawOrder.userId).trim();
    if (!userId) return;

    countsByUser[userId] = (countsByUser[userId] || 0) + 1;
  });
}

async function computeCityWinners({ city, usersByUid, window }) {
  const [shopOrdersSnap, customOrdersSnap] = await Promise.all([
    admin.database().ref(`tenants/${city}/shop-orders`).get(),
    admin.database().ref(`tenants/${city}/custom-orders`).get(),
  ]);

  const countsByUser = {};
  if (shopOrdersSnap.exists()) {
    collectEligibleOrders(
      shopOrdersSnap.val(),
      countsByUser,
      window.weekStartMs,
      window.weekEndMs,
    );
  }
  if (customOrdersSnap.exists()) {
    collectEligibleOrders(
      customOrdersSnap.val(),
      countsByUser,
      window.weekStartMs,
      window.weekEndMs,
    );
  }

  const ranked = Object.entries(countsByUser)
    .map(([uid, orders]) => ({
      uid,
      orders,
      name: displayNameForUser(uid, usersByUid),
    }))
    .sort((a, b) => {
      const byOrders = b.orders - a.orders;
      if (byOrders !== 0) return byOrders;
      return a.name.toLowerCase().localeCompare(b.name.toLowerCase());
    });

  const winners = ranked.slice(0, 3).map((row, index) => ({
    ...row,
    rank: index + 1,
    rewardAmount: WEEKLY_REWARD_PRIZES[index] || 0,
  }));

  return {
    totalParticipants: ranked.length,
    winners,
  };
}

async function announceWinnersForCity({ city, usersByUid, window }) {
  const tenantRef = admin.database().ref(`tenants/${city}`);
  const historyRef = tenantRef.child(
    `weekly-rewards/history/${window.weekKey}`,
  );
  const existing = await historyRef.get();
  if (existing.exists()) {
    return {
      city,
      weekKey: window.weekKey,
      skipped: true,
      reason: "already_announced",
    };
  }

  const { totalParticipants, winners } = await computeCityWinners({
    city,
    usersByUid,
    window,
  });

  const winnersByRank = {};
  const winnerWrites = [];

  const voucherExpiryMs = window.nextWeekStartMs + 6 * DAY_MS;
  const nowClient = Date.now();

  winners.forEach((winner) => {
    const voucherId = `weekly_${window.weekKey}_p${winner.rank}_${city}`;
    winnersByRank[String(winner.rank)] = {
      uid: winner.uid,
      name: winner.name,
      orders: winner.orders,
      rank: winner.rank,
      rewardAmount: winner.rewardAmount,
      voucherId,
    };

    winnerWrites.push(
      admin
        .database()
        .ref(`users/${winner.uid}/weeklyRewardVouchers/${voucherId}`)
        .set({
          voucherId,
          type: "weekly_winner",
          city,
          weekKey: window.weekKey,
          rank: winner.rank,
          amount: winner.rewardAmount,
          minOrder: 0,
          maxUse: 1,
          used: false,
          status: "active",
          title: `Weekly Winner #${winner.rank}`,
          description: `You won Rs.${winner.rewardAmount} off in weekly rewards.`,
          issuedAt: admin.database.ServerValue.TIMESTAMP,
          issuedAtClient: nowClient,
          expiresAt: voucherExpiryMs,
        }),
    );
  });

  await Promise.all(winnerWrites);

  const historyPayload = {
    weekKey: window.weekKey,
    city,
    minimumOrderAmount: WEEKLY_REWARD_MIN_ORDER,
    contestStartMs: window.weekStartMs,
    contestEndMs: window.weekEndMs,
    nextWeekStartMs: window.nextWeekStartMs,
    windowLabel: window.windowLabel,
    totalParticipants,
    winners: winnersByRank,
    announcedAt: admin.database.ServerValue.TIMESTAMP,
    announcedAtClient: nowClient,
  };

  await historyRef.set(historyPayload);
  await tenantRef
    .child("weekly-rewards/latest-announcement")
    .set(historyPayload);

  return {
    city,
    weekKey: window.weekKey,
    winnerCount: winners.length,
    totalParticipants,
    skipped: false,
  };
}

exports.announceWeeklyRewardWinners = functions.pubsub
  .schedule("5 0 * * 0")
  .timeZone("Asia/Karachi")
  .onRun(async () => {
    const window = getWeeklyRewardWindowInPk();

    if (window.weekday !== 0) {
      console.log("Skipping weekly rewards announcement: not Sunday in PK.", {
        weekKey: window.weekKey,
      });
      return null;
    }

    const usersSnap = await admin.database().ref("users").get();
    const usersByUid =
      usersSnap.exists() && typeof usersSnap.val() === "object"
        ? usersSnap.val()
        : {};

    const results = [];
    for (const rawCity of WEEKLY_REWARD_CITIES) {
      const city = normalizeCity(rawCity);
      const result = await announceWinnersForCity({
        city,
        usersByUid,
        window,
      });
      results.push(result);
    }

    console.log("Weekly reward announcement completed.", {
      weekKey: window.weekKey,
      windowLabel: window.windowLabel,
      results,
    });

    return null;
  });
