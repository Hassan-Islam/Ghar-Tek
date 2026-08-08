-- GharTek: PostgreSQL store that faithfully emulates Firebase Realtime Database.
--
-- RTDB is a JSON tree that only ever stores scalar values at the leaves
-- (empty objects do not exist). We mirror that exactly with a leaf table:
-- every row is one leaf, keyed by its full slash-path. A subtree is simply
-- every row whose path equals P or begins with 'P/'.
--
-- This keeps behaviour identical to Firebase while being 100% real PostgreSQL.

CREATE TABLE IF NOT EXISTS rtdb_nodes (
  db_name    text        NOT NULL DEFAULT 'main',
  path       text        NOT NULL,
  value      jsonb       NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (db_name, path)
);

-- Prefix scans ( path LIKE 'parent/%' ) use this index thanks to
-- text_pattern_ops. Also serves point lookups on (db_name, path).
CREATE INDEX IF NOT EXISTS rtdb_nodes_path_prefix_idx
  ON rtdb_nodes (db_name, path text_pattern_ops);

-- NOTE: we intentionally do NOT index the `value` column globally. Most reads
-- happen by path prefix (see src/rtdb.js) and a B-tree index on jsonb breaks on
-- large leaf values (e.g. base64 images) because a single index entry cannot
-- exceed ~8 KB.
--
-- EXCEPTION: the `orderByChild('status').equalTo(...)` fast path filters on the
-- tiny `.../status` leaves (short strings like "available"). A PARTIAL index
-- limited to those leaves is safe (values are small) and makes status queries
-- fast under load instead of scanning every order in the tenant subtree.
CREATE INDEX IF NOT EXISTS rtdb_status_value_idx
  ON rtdb_nodes (db_name, value, path text_pattern_ops)
  WHERE path LIKE '%/status';

-- Same idea for orderByChild('userId').equalTo(uid) (customer "my orders").
-- userId leaves are short uid strings, so a partial B-tree on them is safe.
CREATE INDEX IF NOT EXISTS rtdb_userid_value_idx
  ON rtdb_nodes (db_name, value, path text_pattern_ops)
  WHERE path LIKE '%/userId';
