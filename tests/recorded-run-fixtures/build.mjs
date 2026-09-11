// Synthetic test packaging; never exports Train source directories.
import { readFileSync } from 'node:fs';
import { crc32, deflateRawSync } from 'node:zlib';
import { canonical, SCHEMA_DIGEST, WIRE_VERSION } from '../../deploy/recorded-run/validation.mjs';
import { semanticDigest } from '../../deploy/recorded-run/bundle.mjs';
import { digest } from '../../deploy/recorded-run/store.mjs';
export const fixture = () => {
  const value = JSON.parse(readFileSync(new URL('./synthetic.json', import.meta.url)));
  value.manifest.format_version = WIRE_VERSION;
  return value;
};

export function entriesFor(f) {
  const entries = new Map(), lines = rows => Buffer.from(rows.map(r => canonical(r) + '\n').join(''));
  entries.set('records/events.ndjson', lines(f.events));
  if (f.accounting !== null) entries.set('records/accounting.ndjson', lines(f.accounting));
  entries.set('reports/omissions.json', Buffer.from(canonical(f.report)));
  const m = structuredClone(f.manifest);
  m.contract_schema_sha256 = SCHEMA_DIGEST;
  m.entries = [...entries].sort(([a], [b]) => a < b ? -1 : 1).map(([path, bytes]) => ({ path,
    media_type: path.endsWith('.ndjson') ? 'application/x-ndjson' : 'application/json',
    bytes: bytes.length, sha256: digest(bytes) }));
  m.bundle_id = digest('ai-ascension.recorded-run.v1/bundle-id\0' + canonical(m.recording.identity));
  m.integrity.bundle_semantic_digest = semanticDigest(m);
  entries.set('manifest.json', Buffer.from(canonical(m)));
  return entries;
}

export function zip(entries, compressed = false) {
  const parts = [], headers = [];
  let offset = 0;
  for (const [name, value] of [...entries].sort(([a], [b]) => a < b ? -1 : 1)) {
    const n = Buffer.from(name), data = compressed ? deflateRawSync(value) : value;
    const local = Buffer.alloc(30), central = Buffer.alloc(46), method = compressed ? 8 : 0;
    local.writeUInt32LE(0x04034b50); local.writeUInt16LE(20, 4); local.writeUInt16LE(method, 8);
    local.writeUInt32LE(crc32(value), 14); local.writeUInt32LE(data.length, 18);
    local.writeUInt32LE(value.length, 22); local.writeUInt16LE(n.length, 26);
    central.writeUInt32LE(0x02014b50); central.writeUInt16LE(20, 4); central.writeUInt16LE(20, 6);
    central.writeUInt16LE(method, 10); central.writeUInt32LE(crc32(value), 16);
    central.writeUInt32LE(data.length, 20); central.writeUInt32LE(value.length, 24);
    central.writeUInt16LE(n.length, 28); central.writeUInt32LE(offset, 42);
    parts.push(local, n, data); headers.push(central, n); offset += local.length + n.length + data.length;
  }
  const central = Buffer.concat(headers), end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50); end.writeUInt16LE(entries.size, 8); end.writeUInt16LE(entries.size, 10);
  end.writeUInt32LE(central.length, 12); end.writeUInt32LE(offset, 16);
  return Buffer.concat([...parts, central, end]);
}
export const bundleFor = (f, compressed = false) => zip(entriesFor(f), compressed);
