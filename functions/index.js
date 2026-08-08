const functions = require("firebase-functions/v1");
const admin = require("firebase-admin");

if (!admin.apps.length) {
  admin.initializeApp();
}

function getDb() {
  return admin.database();
}

function getMessaging() {
  return admin.messaging();
}

const DEFAULT_CITY = "vehari";
const INVALID_TOKEN_ERRORS = new Set([
  "messaging/registration-token-not-registered",
  "messaging/invalid-registration-token",
]);

function asString(value) {
  if (value === null || value === undefined) return "";
  return String(value).trim();
}

function asMap(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return {};
  }
  return value;
}

function normalizeCity(value) {
  const v = asString(value).toLowerCase();
  if (v === "islamabad" || v === "isb" || v === "islamabad_city") {
    return "islamabad";
  }
  if (v === "vehari") {
    return "vehari";
  }
  return DEFAULT_CITY;
}

function buildMessageText(notification, fallbackTitle, fallbackBody) {
  const record = asMap(notification);
  const title = asString(record.title) || fallbackTitle;
  const body = asString(record.body) || fallbackBody;
  return { title, body };
}

function buildDataPayload({
  type,
  city,
  notificationId,
  orderId,
  source,
  targetUserId,
}) {
  const raw = {
    type,
    city,
    notificationId,
    orderId,
    source,
    targetUserId,
  };

  const data = {};
  for (const [key, value] of Object.entries(raw)) {
    if (value === null || value === undefined) continue;
    const text = asString(value);
    if (!text) continue;
    data[key] = text;
  }
  return data;
}

function addTokensFromUser({ tokens, userData, roleFilter, cityFilter }) {
  const user = asMap(userData);
  const userRole = asString(user.role).toLowerCase() || "customer";
  const fallbackCity = normalizeCity(
    userRole === "admin" ? user.adminCity : user.userCity,
  );

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
    const snap = await getDb().ref(`users/${userId}`).once("value");
    if (snap.exists()) {
      addTokensFromUser({
        tokens,
        userData: snap.val(),
        roleFilter,
        cityFilter,
      });
    }
    return Array.from(tokens);
  }

  const usersSnap = await getDb().ref("users").once("value");
  if (!usersSnap.exists()) {
    return [];
  }

  const users = asMap(usersSnap.val());
  for (const userData of Object.values(users)) {
    addTokensFromUser({
      tokens,
      userData,
      roleFilter,
      cityFilter,
    });
  }

  return Array.from(tokens);
}

async function cleanupInvalidTokensForUser({ userId, invalidTokens }) {
  if (!userId || invalidTokens.length === 0) return;

  const tokensSnap = await getDb()
    .ref(`users/${userId}/fcmTokens`)
    .once("value");
  if (!tokensSnap.exists()) return;

  const tokenMap = asMap(tokensSnap.val());
  const updates = {};

  for (const [key, value] of Object.entries(tokenMap)) {
    const row = typeof value === "string" ? { token: value } : asMap(value);
    const token = asString(row.token);
    if (!token) continue;
    if (invalidTokens.includes(token)) {
      updates[key] = null;
    }
  }

  if (Object.keys(updates).length > 0) {
    await getDb().ref(`users/${userId}/fcmTokens`).update(updates);
  }
}

async function sendToTokens({
  tokens,
  title,
  body,
  data,
  userIdForCleanup = "",
}) {
  if (!tokens || tokens.length === 0) {
    return {
      successCount: 0,
      failureCount: 0,
      invalidTokens: [],
    };
  }

  const response = await getMessaging().sendEachForMulticast({
    tokens,
    notification: { title, body },
    data,
    android: {
      priority: "high",
      notification: {
        channelId: "ghartek_main",
        sound: "default",
      },
    },
    apns: {
      headers: {
        "apns-priority": "10",
      },
      payload: {
        aps: {
          sound: "default",
        },
      },
    },
  });

  const invalidTokens = [];
  response.responses.forEach((r, index) => {
    const code = r.error && r.error.code ? r.error.code : "";
    if (INVALID_TOKEN_ERRORS.has(code)) {
      invalidTokens.push(tokens[index]);
    }
  });

  if (userIdForCleanup && invalidTokens.length > 0) {
    await cleanupInvalidTokensForUser({
      userId: userIdForCleanup,
      invalidTokens,
    });
  }

  return {
    successCount: response.successCount,
    failureCount: response.failureCount,
    invalidTokens,
  };
}

async function markDeliveryStatus(snapshot, payload) {
  await snapshot.ref.child("_delivery").set({
    ...payload,
    sentAt: admin.database.ServerValue.TIMESTAMP,
  });
}

async function handleUserNotification({
  snapshot,
  city,
  userId,
  notificationId,
  source,
}) {
  const notification = asMap(snapshot.val());
  const cityValue = city
    ? normalizeCity(city)
    : normalizeCity(notification.city);
  const { title, body } = buildMessageText(
    notification,
    "Order Update",
    "You have a new update from GharTek.",
  );

  const data = buildDataPayload({
    type: asString(notification.type || "user_notification"),
    city: cityValue,
    notificationId,
    orderId: notification.orderId,
    source,
    targetUserId: userId,
  });

  const tokens = await collectTokens({ userId });
  const result = await sendToTokens({
    tokens,
    title,
    body,
    data,
    userIdForCleanup: userId,
  });

  await markDeliveryStatus(snapshot, {
    channel: "user",
    target: userId,
    city: cityValue,
    tokensTried: tokens.length,
    successCount: result.successCount,
    failureCount: result.failureCount,
  });

  return null;
}

async function handleRoleInboxNotification({
  snapshot,
  city,
  role,
  notificationId,
  source,
  defaultTitle,
  defaultBody,
}) {
  const notification = asMap(snapshot.val());
  const cityFromPayload = asString(notification.city);
  const cityValue = city
    ? normalizeCity(city)
    : cityFromPayload
      ? normalizeCity(cityFromPayload)
      : "";
  if (!cityValue) {
    await markDeliveryStatus(snapshot, {
      channel: `${role}_inbox`,
      city: "unknown",
      tokensTried: 0,
      successCount: 0,
      failureCount: 0,
      error: "missing_city",
    });
    return null;
  }

  const { title, body } = buildMessageText(
    notification,
    defaultTitle,
    defaultBody,
  );

  const data = buildDataPayload({
    type: asString(notification.type || `${role}_notification`),
    city: cityValue || DEFAULT_CITY,
    notificationId,
    orderId: notification.orderId || asMap(notification.details).orderId,
    source,
  });

  const tokens = await collectTokens({ role, city: cityValue });
  const result = await sendToTokens({
    tokens,
    title,
    body,
    data,
  });

  await markDeliveryStatus(snapshot, {
    channel: `${role}_inbox`,
    city: cityValue || "all",
    tokensTried: tokens.length,
    successCount: result.successCount,
    failureCount: result.failureCount,
  });

  return null;
}

async function handleBroadcastNotification({
  snapshot,
  city,
  notificationId,
  source,
}) {
  const notification = asMap(snapshot.val());
  const cityFromPayload = asString(notification.city);
  const cityValue = city
    ? normalizeCity(city)
    : cityFromPayload
      ? normalizeCity(cityFromPayload)
      : "";
  if (!cityValue) {
    await markDeliveryStatus(snapshot, {
      channel: "broadcast",
      city: "unknown",
      tokensTried: 0,
      successCount: 0,
      failureCount: 0,
      error: "missing_city",
    });
    return null;
  }

  const { title, body } = buildMessageText(
    notification,
    "GharTek Announcement",
    "You have a new announcement.",
  );

  const data = buildDataPayload({
    type: asString(notification.type || "broadcast"),
    city: cityValue || DEFAULT_CITY,
    notificationId,
    source,
  });

  const tokens = await collectTokens({ city: cityValue });
  const result = await sendToTokens({
    tokens,
    title,
    body,
    data,
  });

  await markDeliveryStatus(snapshot, {
    channel: "broadcast",
    city: cityValue || "all",
    tokensTried: tokens.length,
    successCount: result.successCount,
    failureCount: result.failureCount,
  });

  return null;
}

exports.pushTenantUserNotification = functions.database
  .ref("/tenants/{city}/notifications/user/{userId}/{notificationId}")
  .onCreate(async (snapshot, context) => {
    return handleUserNotification({
      snapshot,
      city: context.params.city,
      userId: context.params.userId,
      notificationId: context.params.notificationId,
      source: "tenant_notifications_user",
    });
  });

exports.pushLegacyUserNotification = functions.database
  .ref("/notifications/user/{userId}/{notificationId}")
  .onCreate(async (snapshot, context) => {
    return handleUserNotification({
      snapshot,
      city: "",
      userId: context.params.userId,
      notificationId: context.params.notificationId,
      source: "legacy_notifications_user",
    });
  });

exports.pushTenantAdminInboxNotification = functions.database
  .ref("/tenants/{city}/notifications/admin/inbox/{notificationId}")
  .onCreate(async (snapshot, context) => {
    return handleRoleInboxNotification({
      snapshot,
      city: context.params.city,
      role: "admin",
      notificationId: context.params.notificationId,
      source: "tenant_notifications_admin_inbox",
      defaultTitle: "New Order",
      defaultBody: "A new order has been received.",
    });
  });

exports.pushLegacyAdminInboxNotification = functions.database
  .ref("/notifications/admin/inbox/{notificationId}")
  .onCreate(async (snapshot, context) => {
    return handleRoleInboxNotification({
      snapshot,
      city: "",
      role: "admin",
      notificationId: context.params.notificationId,
      source: "legacy_notifications_admin_inbox",
      defaultTitle: "New Order",
      defaultBody: "A new order has been received.",
    });
  });

exports.pushTenantMerchantNotification = functions.database
  .ref("/tenants/{city}/notifications/merchant/{merchantId}/{notificationId}")
  .onCreate(async (snapshot, context) => {
    return handleUserNotification({
      snapshot,
      city: context.params.city,
      userId: context.params.merchantId,
      notificationId: context.params.notificationId,
      source: "tenant_notifications_merchant",
    });
  });

exports.pushLegacyMerchantNotification = functions.database
  .ref("/notifications/merchant/{merchantId}/{notificationId}")
  .onCreate(async (snapshot, context) => {
    return handleUserNotification({
      snapshot,
      city: "",
      userId: context.params.merchantId,
      notificationId: context.params.notificationId,
      source: "legacy_notifications_merchant",
    });
  });

exports.pushTenantRiderInboxNotification = functions.database
  .ref("/tenants/{city}/notifications/rider/inbox/{notificationId}")
  .onCreate(async (snapshot, context) => {
    return handleRoleInboxNotification({
      snapshot,
      city: context.params.city,
      role: "rider",
      notificationId: context.params.notificationId,
      source: "tenant_notifications_rider_inbox",
      defaultTitle: "New Delivery Task",
      defaultBody: "A delivery order is ready for pickup.",
    });
  });

exports.pushLegacyRiderInboxNotification = functions.database
  .ref("/notifications/rider/inbox/{notificationId}")
  .onCreate(async (snapshot, context) => {
    return handleRoleInboxNotification({
      snapshot,
      city: "",
      role: "rider",
      notificationId: context.params.notificationId,
      source: "legacy_notifications_rider_inbox",
      defaultTitle: "New Delivery Task",
      defaultBody: "A delivery order is ready for pickup.",
    });
  });

exports.pushTenantBroadcastNotification = functions.database
  .ref("/tenants/{city}/notifications/broadcast/{notificationId}")
  .onCreate(async (snapshot, context) => {
    return handleBroadcastNotification({
      snapshot,
      city: context.params.city,
      notificationId: context.params.notificationId,
      source: "tenant_notifications_broadcast",
    });
  });

exports.pushLegacyBroadcastNotification = functions.database
  .ref("/notifications/broadcast/{notificationId}")
  .onCreate(async (snapshot, context) => {
    return handleBroadcastNotification({
      snapshot,
      city: "",
      notificationId: context.params.notificationId,
      source: "legacy_notifications_broadcast",
    });
  });

async function cleanupNode(ref, cutoff) {
  const snap = await ref.once("value");
  if (!snap.exists()) return;
  const updates = {};
  
  snap.forEach(childSnap => {
    const data = childSnap.val();
    let timestamp = data.createdAt || data.updatedAt;
    if (timestamp && timestamp < cutoff) {
      updates[childSnap.key] = null;
    }
  });
  
  if (Object.keys(updates).length > 0) {
    await ref.update(updates);
  }
}

async function cleanupUserChats(cityRef, cutoff) {
  const snap = await cityRef.child("chats").once("value");
  if (!snap.exists()) return;
  
  for (const userId of Object.keys(snap.val())) {
    const userChatsRef = cityRef.child(`chats/${userId}`);
    const userChatsSnap = await userChatsRef.once("value");
    if (!userChatsSnap.exists()) continue;
    
    const updates = {};
    userChatsSnap.forEach(chatSnap => {
      const data = chatSnap.val();
      const meta = data.meta || {};
      const timestamp = meta.updatedAt || meta.lastMessageAt || meta.createdAt;
      if (timestamp && timestamp < cutoff) {
        updates[chatSnap.key] = null;
      }
    });
    
    if (Object.keys(updates).length > 0) {
      await userChatsRef.update(updates);
    }
  }
}

async function cleanupRiderChats(cityRef, cutoff) {
  const snap = await cityRef.child("rider_chats").once("value");
  if (!snap.exists()) return;
  
  const updates = {};
  snap.forEach(chatSnap => {
    const data = chatSnap.val();
    const meta = data.meta || {};
    const timestamp = meta.updatedAt || meta.lastMessageAt || meta.createdAt;
    if (timestamp && timestamp < cutoff) {
      updates[chatSnap.key] = null;
    }
  });
  
  if (Object.keys(updates).length > 0) {
    await cityRef.child("rider_chats").update(updates);
  }
}

exports.cleanupOldData = functions.pubsub
  .schedule("every 1 hours")
  .onRun(async (context) => {
    const cutoff = Date.now() - 24 * 60 * 60 * 1000;
    const db = getDb();
    
    const tenantsSnap = await db.ref("tenants").once("value");
    if (tenantsSnap.exists()) {
      const tenants = tenantsSnap.val();
      for (const city of Object.keys(tenants)) {
        const cityRef = db.ref(`tenants/${city}`);
        await cleanupNode(cityRef.child("notifications/admin/inbox"), cutoff);
        await cleanupUserChats(cityRef, cutoff);
        await cleanupRiderChats(cityRef, cutoff);
      }
    }
    
    await cleanupNode(db.ref("notifications/admin/inbox"), cutoff);
    
    const legacyChatsSnap = await db.ref("chats").once("value");
    if (legacyChatsSnap.exists()) {
      for (const userId of Object.keys(legacyChatsSnap.val())) {
        const userChatsRef = db.ref(`chats/${userId}`);
        const userChatsSnap = await userChatsRef.once("value");
        if (!userChatsSnap.exists()) continue;
        
        const updates = {};
        userChatsSnap.forEach(chatSnap => {
          const data = chatSnap.val();
          const meta = data.meta || {};
          const timestamp = meta.updatedAt || meta.lastMessageAt || meta.createdAt;
          if (timestamp && timestamp < cutoff) {
            updates[chatSnap.key] = null;
          }
        });
        
        if (Object.keys(updates).length > 0) {
          await userChatsRef.update(updates);
        }
      }
    }
    
    const legacyRiderChatsSnap = await db.ref("rider_chats").once("value");
    if (legacyRiderChatsSnap.exists()) {
      const updates = {};
      legacyRiderChatsSnap.forEach(chatSnap => {
        const data = chatSnap.val();
        const meta = data.meta || {};
        const timestamp = meta.updatedAt || meta.lastMessageAt || meta.createdAt;
        if (timestamp && timestamp < cutoff) {
          updates[chatSnap.key] = null;
        }
      });
      if (Object.keys(updates).length > 0) {
        await db.ref("rider_chats").update(updates);
      }
    }
    
    return null;
  });
