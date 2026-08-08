// Firebase-style push id generator: 20 chars, lexicographically ordered by
// time, so ordering-by-key keeps the same chronological behaviour the app
// relied on with RTDB .push().
const PUSH_CHARS =
  "-0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ_abcdefghijklmnopqrstuvwxyz";

let lastPushTime = 0;
let lastRandChars = [];

function generatePushId(now = Date.now()) {
  const duplicateTime = now === lastPushTime;
  lastPushTime = now;

  const timeStampChars = new Array(8);
  let t = now;
  for (let i = 7; i >= 0; i--) {
    timeStampChars[i] = PUSH_CHARS.charAt(t % 64);
    t = Math.floor(t / 64);
  }
  let id = timeStampChars.join("");

  if (!duplicateTime) {
    for (let i = 0; i < 12; i++) {
      lastRandChars[i] = Math.floor(Math.random() * 64);
    }
  } else {
    let i = 11;
    for (; i >= 0 && lastRandChars[i] === 63; i--) {
      lastRandChars[i] = 0;
    }
    if (i >= 0) lastRandChars[i]++;
  }

  for (let i = 0; i < 12; i++) {
    id += PUSH_CHARS.charAt(lastRandChars[i]);
  }
  return id;
}

module.exports = { generatePushId };
