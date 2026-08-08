# GharTek Backend (PostgreSQL replacement for Firebase Realtime Database)

This backend replaces **only** Firebase Realtime Database. Firebase Auth (login)
and FCM (push notifications) stay on Firebase. It exposes a small REST + WebSocket
API that the Flutter app talks to through a drop-in Firebase-compatible shim
(`lib/services/db/`).

## What it does
- Stores data in real PostgreSQL, faithfully emulating RTDB's JSON-tree model
  (leaf rows keyed by slash-path).
- REST: get / set / update / push / remove / query.
- WebSocket realtime: `onValue`, `onChildAdded`, `onChildChanged`, `onChildRemoved`.
- Verifies the Firebase ID token the app sends (login stays on Firebase).
- Sends FCM push when notifications are written (the old Cloud Functions job).

## Run locally

```bash
cd backend
cp .env.example .env
docker compose up -d          # starts PostgreSQL on host port 5433
npm install
npm start                     # backend on http://localhost:8080, ws://localhost:8080/rtdb
```

## Import existing data (no data loss)
1. Firebase Console -> Realtime Database -> (⋮) -> Export JSON, for both databases.
2. Save as `backend/data/main.json` (pak-delivers) and `backend/data/ratings.json`.
3. Run:

```bash
npm run import -- --truncate
```

## Enable push notifications (optional)
Download a service account key (Firebase Console -> Project Settings ->
Service Accounts -> Generate new private key) and save it as
`backend/secrets/serviceAccountKey.json`. Auth verification works without it.

## Endpoints
| Method | Path | Body |
| --- | --- | --- |
| POST | /v1/get | `{ db, path }` |
| POST | /v1/set | `{ db, path, value }` |
| POST | /v1/update | `{ db, path, value }` |
| POST | /v1/push | `{ db, path, value }` |
| POST | /v1/remove | `{ db, path }` |
| POST | /v1/query | `{ db, path, query }` |

`db` is `"main"` (pak-delivers) or `"ratings"` (ghartek-c3399).
