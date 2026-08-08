const admin = require('firebase-admin');

const servicePath = 'C:/Users/Ahsan/Downloads/pak-delivers-firebase-adminsdk-fbsvc-9bc73d9604.json';
const service = require(servicePath);

admin.initializeApp({
  credential: admin.credential.cert(service),
  databaseURL: 'https://pak-delivers-default-rtdb.firebaseio.com',
});

const PKT_OFFSET_MS = 5 * 60 * 60 * 1000;
const DAY_MS = 24 * 60 * 60 * 1000;

function pad2(v) { return String(v).padStart(2, '0'); }
function formatPkDateKey(shiftedMs) {
  const d = new Date(shiftedMs);
  return `${d.getUTCFullYear()}${pad2(d.getUTCMonth()+1)}${pad2(d.getUTCDate())}`;
}
function startOfPkDayShifted(shiftedMs) {
  const d = new Date(shiftedMs);
  return Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate());
}
function currentWeekKey(nowMs = Date.now()) {
  const shiftedNowMs = nowMs + PKT_OFFSET_MS;
  const shiftedNow = new Date(shiftedNowMs);
  const weekday = shiftedNow.getUTCDay();
  const todayStartShiftedMs = startOfPkDayShifted(shiftedNowMs);
  const daysSinceMonday = (weekday + 6) % 7;
  const mondayStartShiftedMs = todayStartShiftedMs - daysSinceMonday * DAY_MS;
  return formatPkDateKey(mondayStartShiftedMs);
}
function lastWeekKey(nowMs = Date.now()) {
  const shiftedNowMs = nowMs + PKT_OFFSET_MS;
  const shiftedNow = new Date(shiftedNowMs);
  const weekday = shiftedNow.getUTCDay();
  const todayStartShiftedMs = startOfPkDayShifted(shiftedNowMs);
  const daysSinceMonday = (weekday + 6) % 7;
  const thisMonday = todayStartShiftedMs - daysSinceMonday * DAY_MS;
  return formatPkDateKey(thisMonday - 7 * DAY_MS);
}

async function fetchCity(city, wantedKey) {
  const rootRef = admin.database().ref(`tenants/${city}/weekly-rewards/history`);
  const fullSnap = await rootRef.get();
  const all = (fullSnap.exists() && typeof fullSnap.val() === 'object') ? fullSnap.val() : {};
  const keys = Object.keys(all).sort();

  let usedKey = wantedKey;
  let payload = all[wantedKey] || null;

  if (!payload && keys.length > 0) {
    const beforeOrEqual = keys.filter(k => k <= wantedKey);
    usedKey = (beforeOrEqual.length ? beforeOrEqual[beforeOrEqual.length - 1] : keys[keys.length - 1]);
    payload = all[usedKey] || null;
  }

  const winnersMap = payload && typeof payload === 'object' && payload.winners && typeof payload.winners === 'object'
    ? payload.winners : {};
  const winners = Object.values(winnersMap)
    .map(w => ({
      rank: Number(w.rank || 0),
      name: (w.name || '').toString(),
      uid: (w.uid || '').toString(),
      orders: Number(w.orders || 0),
      rewardAmount: Number(w.rewardAmount || 0),
    }))
    .sort((a,b) => a.rank - b.rank);

  return {
    city,
    requestedWeekKey: wantedKey,
    usedWeekKey: usedKey,
    totalParticipants: payload?.totalParticipants ?? null,
    announcedAt: payload?.announcedAtClient ?? payload?.announcedAt ?? null,
    winners,
    availableWeekKeys: keys,
  };
}

(async () => {
  try {
    const now = Date.now();
    const reqKey = lastWeekKey(now);
    const out = {
      nowIso: new Date(now).toISOString(),
      currentWeekKey: currentWeekKey(now),
      requestedLastWeekKey: reqKey,
      results: await Promise.all([
        fetchCity('vehari', reqKey),
        fetchCity('islamabad', reqKey),
      ]),
    };
    console.log(JSON.stringify(out, null, 2));
  } catch (e) {
    console.error('ERROR', e && e.stack ? e.stack : e);
    process.exitCode = 1;
  } finally {
    try { await admin.app().delete(); } catch (_) {}
  }
})();
