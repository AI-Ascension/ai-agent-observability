// Local import/outbox state, not a replacement for the MLflow/Laminar stores.
import { DatabaseSync } from 'node:sqlite';
import { createHash } from 'node:crypto';
import { openSync, closeSync, fstatSync, constants } from 'node:fs';

export const digest = value => createHash('sha256').update(value).digest('hex');
export const runKey = identity => digest(JSON.stringify(['recorded-run', identity.namespace, identity.value]));

export class ImportStore {
  constructor(path, { readOnly = false } = {}) {
    if (readOnly) {
      let fd;
      try {
        fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
        if (!fstatSync(fd).isFile()) throw new Error('database_not_regular');
      } catch (error) {
        if (error.code === 'ENOENT') throw new Error('database_not_found');
        if (error.code === 'ELOOP' || error.message === 'database_not_regular') throw new Error('database_not_regular');
        throw new Error('database_unreadable');
      } finally { if (fd !== undefined) closeSync(fd); }
      try {
        this.db = new DatabaseSync(path, { readOnly: true });
        // Inspection must neither initialize nor repair a database schema.
        this.db.prepare('SELECT run_id,digest,summary FROM revisions LIMIT 0').all();
        this.db.prepare('SELECT run_id,digest,part,state FROM outbox LIMIT 0').all();
      } catch {
        this.db?.close();
        throw new Error('database_invalid');
      }
      return;
    }
    if (path !== ':memory:') {
      const fd = openSync(path, constants.O_CREAT | constants.O_RDWR | constants.O_NOFOLLOW, 0o600);
      closeSync(fd);
    }
    this.db = new DatabaseSync(path);
    this.db.exec(`PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;
      CREATE TABLE IF NOT EXISTS runs (id TEXT PRIMARY KEY, namespace TEXT NOT NULL,
        value TEXT NOT NULL, UNIQUE(namespace,value));
      CREATE TABLE IF NOT EXISTS revisions (run_id TEXT NOT NULL REFERENCES runs(id),
        digest TEXT NOT NULL, summary TEXT NOT NULL, PRIMARY KEY(run_id,digest));
      CREATE TABLE IF NOT EXISTS outbox (run_id TEXT NOT NULL, digest TEXT NOT NULL,
        part INTEGER NOT NULL, body TEXT NOT NULL, endpoint TEXT,
        state TEXT NOT NULL CHECK(state IN ('pending','sending','acknowledged','unknown')),
        PRIMARY KEY(run_id,digest,part),
        FOREIGN KEY(run_id,digest) REFERENCES revisions(run_id,digest));`);
  }

  stage(summary, makeBodies) {
    const id = runKey(summary.identity);
    this.db.exec('BEGIN IMMEDIATE');
    try {
      const existing = this.db.prepare('SELECT summary FROM revisions WHERE run_id=? AND digest=?')
        .get(id, summary.semanticDigest);
      if (existing) {
        // Adapter projections may change only via an explicit adapter migration,
        // never silently rewriting the first stored snapshot on an import retry.
        this.db.exec('COMMIT');
        return { disposition: 'duplicate', runId: id, semanticDigest: summary.semanticDigest };
      }
      const previous = this.db.prepare('SELECT id FROM runs WHERE id=?').get(id);
      if (previous) {
        const revisions = this.db.prepare('SELECT summary FROM revisions WHERE run_id=?').all(id);
        for (const row of revisions) {
          const prior = JSON.parse(row.summary);
          for (const key of ['name', 'source_format']) {
            if (prior.producer?.[key] !== summary.producer?.[key]) throw new Error('immutable_producer_conflict');
          }
          for (const [key, identity] of Object.entries(prior.identities ?? {})) {
            const next = summary.identities?.[key];
            if (next && (next.namespace !== identity.namespace || next.value !== identity.value))
              throw new Error('immutable_identity_conflict');
          }
          for (const key of ['gameplay', 'process_exit']) {
            const before = prior.evidence?.[key], after = summary.evidence?.[key];
            if (before && after && before !== 'unknown' && after !== 'unknown' && before !== after)
              throw new Error('final_evidence_conflict');
          }
        }
      }
      this.db.prepare('INSERT OR IGNORE INTO runs VALUES (?,?,?)')
        .run(id, summary.identity.namespace, summary.identity.value);
      this.db.prepare('INSERT INTO revisions VALUES (?,?,?)')
        .run(id, summary.semanticDigest, JSON.stringify(summary));
      const bodies = makeBodies(id, summary);
      if (!Array.isArray(bodies) || bodies.length === 0) throw new Error('empty_delivery_projection');
      const insert = this.db.prepare("INSERT INTO outbox VALUES (?,?,?,?,NULL,'pending')");
      bodies.forEach((body, i) => insert.run(id, summary.semanticDigest, i, JSON.stringify(body)));
      this.db.exec('COMMIT');
      return { disposition: previous ? 'revision_added' : 'imported', runId: id,
        semanticDigest: summary.semanticDigest };
    } catch (error) { this.db.exec('ROLLBACK'); throw error; }
  }

  inspect(id) {
    return this.db.prepare('SELECT digest,summary FROM revisions WHERE run_id=? ORDER BY digest')
      .all(id).map(row => ({ ...JSON.parse(row.summary), delivery:
        this.db.prepare('SELECT part,state FROM outbox WHERE run_id=? AND digest=? ORDER BY part')
          .all(id, row.digest) }));
  }

  claim(id, semanticDigest, endpoint) {
    this.db.exec('BEGIN IMMEDIATE');
    try {
      const rows = this.db.prepare('SELECT * FROM outbox WHERE run_id=? AND digest=? ORDER BY part')
        .all(id, semanticDigest);
      if (!rows.length) {
        const revision = this.db.prepare('SELECT 1 FROM revisions WHERE run_id=? AND digest=?').get(id, semanticDigest);
        throw new Error(revision ? 'delivery_outbox_empty' : 'delivery_not_found');
      }
      if (rows.some(row => row.endpoint && row.endpoint !== endpoint)) throw new Error('endpoint_conflict');
      if (rows.some(row => ['sending', 'unknown'].includes(row.state))) throw new Error('delivery_reconciliation_required');
      const row = rows.find(row => row.state === 'pending');
      if (row) this.db.prepare("UPDATE outbox SET state='sending',endpoint=? WHERE run_id=? AND digest=? AND part=?")
        .run(endpoint, id, semanticDigest, row.part);
      this.db.exec('COMMIT');
      return row;
    } catch (error) { this.db.exec('ROLLBACK'); throw error; }
  }

  settle(row, state) {
    if (!['acknowledged', 'unknown'].includes(state)) throw new Error('invalid_delivery_state');
    this.db.prepare("UPDATE outbox SET state=? WHERE run_id=? AND digest=? AND part=? AND state='sending'")
      .run(state, row.run_id, row.digest, row.part);
  }

  close() { this.db.close(); }
}
