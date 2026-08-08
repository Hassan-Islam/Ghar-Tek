// Quick end-to-end check of the backend RTDB semantics + realtime.
const WebSocket = require("ws");

const BASE = "http://localhost:8080";
async function call(ep, body) {
  const r = await fetch(`${BASE}${ep}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  if (!r.ok) throw new Error(`${ep} -> ${r.status} ${await r.text()}`);
  return r.json();
}
const assert = (c, m) => { if (!c) throw new Error("ASSERT FAILED: " + m); console.log("  ok:", m); };

async function main() {
  const city = "tenants/vehari";
  // clean slate
  await call("/v1/remove", { path: "smoketest" });

  // set + get scalar and nested
  await call("/v1/set", { path: "smoketest/users/u1", value: { name: "Ali", role: "customer", orders: 0 } });
  let g = await call("/v1/get", { path: "smoketest/users/u1" });
  assert(g.value.name === "Ali" && g.value.orders === 0, "set/get nested object");

  // update merges, leaves siblings
  await call("/v1/update", { path: "smoketest/users/u1", value: { role: "admin", "profile/city": "vehari" } });
  g = await call("/v1/get", { path: "smoketest/users/u1" });
  assert(g.value.name === "Ali" && g.value.role === "admin" && g.value.profile.city === "vehari", "update merge + nested key");

  // server timestamp sentinel
  await call("/v1/update", { path: "smoketest/users/u1", value: { createdAt: { ".sv": "timestamp" } } });
  g = await call("/v1/get", { path: "smoketest/users/u1" });
  assert(typeof g.value.createdAt === "number" && g.value.createdAt > 1e12, "server timestamp resolved");

  // push generates ordered keys
  const k1 = (await call("/v1/push", { path: `smoketest/${city}/orders`, value: { userId: "u1", total: 100 } })).key;
  const k2 = (await call("/v1/push", { path: `smoketest/${city}/orders`, value: { userId: "u2", total: 200 } })).key;
  assert(k1 < k2, "push ids are chronologically ordered");

  // query orderByChild equalTo
  let q = await call("/v1/query", { path: `smoketest/${city}/orders`, query: { orderBy: "child", childKey: "userId", equalTo: "u1" } });
  assert(q.order.length === 1 && q.values[q.order[0]].total === 100, "query orderByChild.equalTo");

  // query limitToLast
  q = await call("/v1/query", { path: `smoketest/${city}/orders`, query: { orderBy: "key", limitToLast: 1 } });
  assert(q.order.length === 1 && q.order[0] === k2, "query limitToLast");

  // remove a child
  await call("/v1/remove", { path: `smoketest/${city}/orders/${k1}` });
  q = await call("/v1/query", { path: `smoketest/${city}/orders`, query: { orderBy: "key" } });
  assert(q.order.length === 1 && q.order[0] === k2, "remove child");

  // arrays round-trip (RTDB stores as 0,1,2 -> returns array)
  await call("/v1/set", { path: "smoketest/list", value: ["a", "b", "c"] });
  g = await call("/v1/get", { path: "smoketest/list" });
  assert(Array.isArray(g.value) && g.value[1] === "b", "array round-trip");

  // realtime: onValue
  await new Promise((resolve, reject) => {
    const ws = new WebSocket("ws://localhost:8080/rtdb");
    let count = 0;
    const timeout = setTimeout(() => reject(new Error("realtime timeout")), 5000);
    ws.on("open", () => ws.send(JSON.stringify({ type: "subscribe", subId: "s1", path: "smoketest/rt", event: "value" })));
    ws.on("message", async (raw) => {
      const m = JSON.parse(raw.toString());
      if (m.type !== "event") return;
      count++;
      if (count === 1) {
        assert(m.value === null, "onValue initial null");
        await call("/v1/set", { path: "smoketest/rt", value: { hello: "world" } });
      } else if (count === 2) {
        assert(m.value && m.value.hello === "world", "onValue live update received");
        clearTimeout(timeout);
        ws.close();
        resolve();
      }
    });
    ws.on("error", reject);
  });

  // realtime: child_added replays + live
  await new Promise((resolve, reject) => {
    const ws = new WebSocket("ws://localhost:8080/rtdb");
    const seen = [];
    const timeout = setTimeout(() => reject(new Error("child_added timeout")), 5000);
    ws.on("open", () => ws.send(JSON.stringify({ type: "subscribe", subId: "c1", path: `smoketest/${city}/orders`, event: "child_added" })));
    ws.on("message", async (raw) => {
      const m = JSON.parse(raw.toString());
      if (m.type !== "event" || m.event !== "child_added") return;
      seen.push(m.key);
      if (seen.length === 1) {
        // one existing child replayed; now add another
        await call("/v1/push", { path: `smoketest/${city}/orders`, value: { userId: "u9", total: 9 } });
      } else if (seen.length === 2) {
        assert(true, "child_added replay + live");
        clearTimeout(timeout);
        ws.close();
        resolve();
      }
    });
    ws.on("error", reject);
  });

  await call("/v1/remove", { path: "smoketest" });
  console.log("\nALL SMOKE TESTS PASSED");
  process.exit(0);
}
main().catch((e) => { console.error("\nSMOKE TEST FAILED:", e.message); process.exit(1); });
