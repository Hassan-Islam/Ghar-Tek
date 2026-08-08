// Helpers to convert between a nested JSON value (how the app thinks about
// data) and the flat leaf rows we store in Postgres (how RTDB actually
// stores data). Only scalars live at the leaves; empty maps/arrays vanish,
// exactly like Firebase.

const SERVER_TIMESTAMP = { ".sv": "timestamp" };

function isPlainObject(v) {
  return v !== null && typeof v === "object" && !Array.isArray(v);
}

// Resolve Firebase server-value sentinels ({".sv":"timestamp"}) to concrete
// values before writing.
function resolveServerValues(value, now = Date.now()) {
  if (Array.isArray(value)) {
    return value.map((v) => resolveServerValues(v, now));
  }
  if (isPlainObject(value)) {
    if (value[".sv"] === "timestamp") return now;
    const out = {};
    for (const [k, v] of Object.entries(value)) {
      out[k] = resolveServerValues(v, now);
    }
    return out;
  }
  return value;
}

// Flatten a nested value rooted at `basePath` into [ [leafPath, scalar], ... ].
// Arrays are stored the RTDB way: as children keyed "0","1","2"...
function flattenLeaves(basePath, value, out = []) {
  if (value === null || value === undefined) {
    return out; // nulls mean "no data" in RTDB
  }
  if (Array.isArray(value)) {
    value.forEach((v, i) => flattenLeaves(joinPath(basePath, String(i)), v, out));
    return out;
  }
  if (isPlainObject(value)) {
    const keys = Object.keys(value);
    if (keys.length === 0) return out; // empty object = nothing stored
    for (const k of keys) {
      flattenLeaves(joinPath(basePath, k), value[k], out);
    }
    return out;
  }
  // scalar leaf
  out.push([basePath, value]);
  return out;
}

// Rebuild a nested value from leaf rows [{path, value}], relative to `basePath`.
// Returns null when there are no rows (RTDB: node does not exist).
function rebuildTree(basePath, rows) {
  if (!rows || rows.length === 0) return null;

  // Exact leaf at basePath => scalar value.
  const exact = rows.find((r) => r.path === basePath);
  if (exact && rows.length === 1) return exact.value;

  const prefix = basePath === "" ? "" : basePath + "/";
  const root = {};
  for (const row of rows) {
    let rel;
    if (row.path === basePath) {
      // Shouldn't happen alongside deeper rows, but guard anyway.
      continue;
    }
    if (prefix !== "" && !row.path.startsWith(prefix)) continue;
    rel = prefix === "" ? row.path : row.path.slice(prefix.length);
    const segs = rel.split("/");
    let node = root;
    for (let i = 0; i < segs.length - 1; i++) {
      const s = segs[i];
      if (!isPlainObject(node[s])) node[s] = {};
      node = node[s];
    }
    node[segs[segs.length - 1]] = row.value;
  }
  return coerceArrays(root);
}

// RTDB returns integer-keyed maps as arrays when keys are contiguous 0..n-1.
// We mirror that so the Dart side receives the same shape it always did.
function coerceArrays(node) {
  if (!isPlainObject(node)) return node;
  const keys = Object.keys(node);
  for (const k of keys) {
    node[k] = coerceArrays(node[k]);
  }
  if (keys.length === 0) return node;
  const allInts = keys.every((k) => /^\d+$/.test(k));
  if (!allInts) return node;
  const idxs = keys.map(Number).sort((a, b) => a - b);
  const contiguous = idxs[0] === 0 && idxs[idxs.length - 1] === idxs.length - 1;
  if (!contiguous) return node;
  return idxs.map((i) => node[String(i)]);
}

function joinPath(base, child) {
  const b = (base || "").replace(/^\/+|\/+$/g, "");
  const c = (child || "").replace(/^\/+|\/+$/g, "");
  if (!b) return c;
  if (!c) return b;
  return `${b}/${c}`;
}

function normalizePath(path) {
  return (path || "").replace(/\\/g, "/").replace(/^\/+|\/+$/g, "");
}

module.exports = {
  SERVER_TIMESTAMP,
  isPlainObject,
  resolveServerValues,
  flattenLeaves,
  rebuildTree,
  coerceArrays,
  joinPath,
  normalizePath,
};
