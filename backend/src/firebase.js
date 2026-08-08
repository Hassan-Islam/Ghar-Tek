const fs = require("fs");
const path = require("path");
const admin = require("firebase-admin");

// Login still runs on Firebase Auth and push still goes through FCM. This
// module initialises the Admin SDK so the backend can (a) verify the ID
// tokens the app sends and (b) send FCM messages (the job the old Cloud
// Functions did on RTDB writes).

let initialized = false;
let hasCredential = false;

function init() {
  if (initialized) return;
  initialized = true;

  const projectId = process.env.FIREBASE_PROJECT_ID || "pak-delivers";
  const credPath = process.env.GOOGLE_APPLICATION_CREDENTIALS;

  try {
    if (credPath && fs.existsSync(path.resolve(credPath))) {
      const serviceAccount = require(path.resolve(credPath));
      admin.initializeApp({
        credential: admin.credential.cert(serviceAccount),
        projectId: serviceAccount.project_id || projectId,
      });
      hasCredential = true;
      console.log("[firebase] initialised with service account (FCM enabled)");
    } else {
      // No service account: token verification still works (Google public
      // keys + project id), but FCM sending is disabled.
      admin.initializeApp({ projectId });
      console.log(
        "[firebase] initialised without service account " +
          "(auth verify OK, FCM push disabled)"
      );
    }
  } catch (e) {
    console.error("[firebase] init failed:", e.message);
  }
}

async function verifyIdToken(token) {
  init();
  return admin.auth().verifyIdToken(token);
}

function messaging() {
  init();
  if (!hasCredential) return null;
  return admin.messaging();
}

module.exports = { init, verifyIdToken, messaging, hasCredential: () => hasCredential };
