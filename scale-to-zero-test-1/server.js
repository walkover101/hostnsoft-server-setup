/**
 * scale-to-zero-test-1 — disposable test app for
 * docs/scale-to-zero-gated-plan.md Steps 3-5.
 *
 * Its whole job is to make data loss VISIBLE. It keeps a monotonically
 * increasing counter plus a row per visit in a SQLite database under
 * DATA_DIR. If the app is stopped and woken and the counter goes
 * backwards — or the database is suddenly empty — data was lost, and
 * the number says so immediately rather than the app quietly looking
 * healthy with a fresh database.
 *
 * Uses better-sqlite3 (the platform's documented storage path) rather
 * than a plain file, deliberately: it produces the real -wal and -shm
 * files alongside the .db, which are exactly what the bind mount has to
 * keep together for SQLite to recover from an abrupt stop.
 *
 * Nothing real depends on this app. Delete it when the plan is done.
 */
const http = require('http');
const fs = require('fs');
const path = require('path');
const Database = require('better-sqlite3');

const PORT = process.env.PORT || 3000;
const DATA_DIR = process.env.DATA_DIR || '/tmp';
const DB_PATH = path.join(DATA_DIR, 'visits.db');

fs.mkdirSync(DATA_DIR, { recursive: true });

const db = new Database(DB_PATH);
// WAL is the mode the real data-safety argument depends on: it is what
// makes an abrupt kill recoverable, PROVIDED .db/-wal/-shm all persist
// together — which is what DATA_DIR being a host bind mount guarantees.
db.pragma('journal_mode = WAL');
db.exec('CREATE TABLE IF NOT EXISTS visit (id INTEGER PRIMARY KEY AUTOINCREMENT, ts TEXT NOT NULL)');

const insert = db.prepare('INSERT INTO visit (ts) VALUES (?)');
const count = db.prepare('SELECT COUNT(*) AS n FROM visit');
const first = db.prepare('SELECT ts FROM visit ORDER BY id ASC LIMIT 1');

http
  .createServer((req, res) => {
    // A health path that does NOT write, so it can be polled during a
    // wake without inflating the counter it is meant to verify.
    if (req.url === '/health') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify({ ok: true, visits: count.get().n }));
    }

    insert.run(new Date().toISOString());
    const total = count.get().n;
    const since = first.get();

    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(
      JSON.stringify(
        {
          app: process.env.APP_NAME || 'scale-to-zero-test-1',
          version: process.env.APP_VERSION || 'unknown',
          dataDir: DATA_DIR,
          dbPath: DB_PATH,
          // THE NUMBER THAT MATTERS. It must never go backwards across a
          // stop/wake cycle. If it resets to 1, the database was lost.
          visits: total,
          firstVisitEver: since ? since.ts : null,
          note: 'visits must only ever increase, including across a scale-to-zero stop and wake',
        },
        null,
        2
      )
    );
  })
  .listen(PORT, '0.0.0.0', () => {
    console.log(`[scale-to-zero-test-1] listening on ${PORT}, db at ${DB_PATH}, visits so far: ${count.get().n}`);
  });
