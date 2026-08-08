const admin = require("./node_modules/firebase-admin");

const DB_URL = "https://pak-delivers-default-rtdb.firebaseio.com";

async function run() {
  try {
    admin.initializeApp({ databaseURL: DB_URL });
    await admin.database().ref("app-config/version").set({
      latest: "4.3.0+50",
      minimum: "1.0.0+0",
      message: "A new version is available on the Play Store.",
      playStoreUrl:
        "https://play.google.com/store/apps/details?id=com.ghartek.app",
      lastUpdated: new Date().toISOString(),
    });
    console.log("SET_OK");
    process.exit(0);
  } catch (e) {
    console.error("SET_ERR", e);
    process.exit(1);
  }
}

run();
