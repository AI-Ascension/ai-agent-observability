import { readFileSync } from 'node:fs';
import { inflateRawSync, crc32 } from 'node:zlib';
import { digest } from './store.mjs';

export const LIMITS = Object.freeze({ archive: 16 * 1024 ** 2, total: 32 * 1024 ** 2,
  entry: 16 * 1024 ** 2, manifest: 256 * 1024, omissions: 1024 ** 2,
  line: 64 * 1024, records: 25000, depth: 32, nodes: 100000 });
export const SCHEMA_DIGEST = 'a6c32127290f4d5e670d8863f97a74a7b8e3e411e735d81394b51fe1578b4eb6';
export const WIRE_VERSION = '1.0.0-candidate.3';
export const INVENTORY_DIGEST = '580c1cf3be4bb3e4eb37b9acd9166808b7386b0eb84286cc0798a0d88e35bb35';
const contractRoot = new URL('../../contract/recorded-run-bundle-v1-candidate3/', import.meta.url);
const inventory = readFileSync(new URL('SHA256SUMS', contractRoot));
if (digest(inventory) !== INVENTORY_DIGEST) throw new Error('contract_inventory_mismatch');
for (const line of inventory.toString('utf8').trim().split('\n')) {
  const [expected, name] = line.split(/\s+/);
  if (digest(readFileSync(new URL(name, contractRoot))) !== expected) throw new Error('contract_file_mismatch');
}
const schemaBytes = readFileSync(new URL('schema.json', contractRoot));
if (digest(schemaBytes) !== SCHEMA_DIGEST) throw new Error('contract_pin_mismatch');
const schema = JSON.parse(schemaBytes);
export function requireThat(condition, code) { if (!condition) throw new Error(code); }

// JCS: emit sorted tokens directly, including integer-like object member names.
export function canonical(value) {
  if (typeof value === 'string') {
    requireThat(value.isWellFormed(), 'invalid_unicode');
    return JSON.stringify(value);
  }
  if (value === null || typeof value === 'boolean') return JSON.stringify(value);
  if (typeof value === 'number') {
    requireThat(Number.isFinite(value), 'invalid_number');
    return JSON.stringify(value);
  }
  if (Array.isArray(value)) return '[' + value.map(canonical).join(',') + ']';
  return '{' + Object.keys(value).sort().map(key => canonical(key) + ':' + canonical(value[key])).join(',') + '}';
}

export function parseCanonical(bytes, limit) {
  requireThat(bytes.length <= limit, 'json_byte_limit');
  const text = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(bytes);
  let depth = 0, quoted = false, escaped = false;
  // Preflight nesting before parsing, so a hostile deep input cannot recurse.
  for (const char of text) {
    if (quoted) {
      if (escaped) escaped = false;
      else if (char === '\\') escaped = true;
      else if (char === '"') quoted = false;
    } else if (char === '"') quoted = true;
    else if (char === '{' || char === '[') requireThat(++depth <= LIMITS.depth, 'json_depth_limit');
    else if (char === '}' || char === ']') depth--;
  }
  const value = JSON.parse(text);
  let nodes = 0;
  function visit(v) {
    requireThat(++nodes <= LIMITS.nodes, 'json_node_limit');
    if (v && typeof v === 'object') for (const x of Object.values(v)) visit(x);
  }
  visit(value);
  // Exact canonical-byte equality also rejects duplicate/escaped-equivalent
  // object keys, whitespace, BOM, rounded numeric encodings and invalid scalars.
  requireThat(canonical(value) === text, 'noncanonical_json');
  return value;
}

// Deliberately limited interpreter for the exact pinned candidate vocabulary.
// This is not presented as a general JSON Schema implementation.
const keywords = new Set(['$schema', '$id', 'title', '$defs', '$ref', 'type', 'properties',
  'required', 'additionalProperties', 'const', 'enum', 'oneOf', 'anyOf', 'items',
  'minItems', 'maxItems', 'uniqueItems', 'minLength', 'maxLength', 'pattern', 'minimum', 'maximum']);
function audit(s) {
  for (const key of Object.keys(s)) requireThat(keywords.has(key), 'unsupported_schema_keyword');
  for (const group of ['properties', '$defs']) for (const child of Object.values(s[group] ?? {})) audit(child);
  for (const group of ['oneOf', 'anyOf']) for (const child of s[group] ?? []) audit(child);
  if (s.items) audit(s.items);
}
audit(schema);
function matches(v, s) {
  if (s.$ref) return matches(v, schema.$defs[s.$ref.split('/').at(-1)]);
  if (s.oneOf && s.oneOf.filter(child => matches(v, child)).length !== 1) return false;
  if (s.anyOf && !s.anyOf.some(child => matches(v, child))) return false;
  if (Object.hasOwn(s, 'const') && canonical(v) !== canonical(s.const)) return false;
  if (s.enum && !s.enum.some(x => canonical(x) === canonical(v))) return false;
  if (s.type) {
    const type = v === null ? 'null' : Array.isArray(v) ? 'array' : typeof v;
    if (s.type === 'integer' ? !Number.isSafeInteger(v) : s.type !== type) return false;
  }
  if (typeof v === 'string') {
    const n = [...v].length;
    if (n < (s.minLength ?? 0) || n > (s.maxLength ?? Infinity)
      || (s.pattern && !new RegExp(s.pattern, 'u').test(v))) return false;
  }
  if (typeof v === 'number' && (v < (s.minimum ?? -Infinity) || v > (s.maximum ?? Infinity))) return false;
  if (Array.isArray(v)) {
    if (v.length < (s.minItems ?? 0) || v.length > (s.maxItems ?? Infinity)) return false;
    if (s.uniqueItems && new Set(v.map(canonical)).size !== v.length) return false;
    if (s.items && !v.every(x => matches(x, s.items))) return false;
  } else if (v && typeof v === 'object') {
    if ((s.required ?? []).some(key => !Object.hasOwn(v, key))) return false;
    for (const key of Object.keys(v)) {
      if (s.properties && Object.hasOwn(s.properties, key)) { if (!matches(v[key], s.properties[key])) return false; }
      else if (s.additionalProperties === false) return false;
    }
  }
  return true;
}
export function validateDocument(value, kind) {
  function inert(v) {
    if (typeof v === 'string') requireThat(!/[\u0000-\u0020\u007f-\u009f]/u.test(v), 'profile_control_character');
    else if (v && typeof v === 'object') for (const x of Object.values(v)) inert(x);
  }
  inert(value);
  requireThat(matches(value, schema.$defs[kind]), `invalid_${kind}`);
}

export function readZip(bytes) {
  requireThat(bytes instanceof Uint8Array && !(bytes.buffer instanceof SharedArrayBuffer), 'archive_byte_type');
  requireThat(bytes.byteLength >= 22 && bytes.byteLength <= LIMITS.archive, 'archive_byte_limit');
  // Bound the supplied view before conversion; never copy a larger backing store.
  bytes = Buffer.from(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  // Candidate subset: no comments, descriptors, ZIP64, extras, or split disks.
  const end = bytes.length - 22;
  requireThat(bytes.readUInt32LE(end) === 0x06054b50, 'zip_end');
  requireThat(bytes.readUInt16LE(end + 4) === 0 && bytes.readUInt16LE(end + 6) === 0
    && bytes.readUInt16LE(end + 20) === 0, 'zip_multi_disk_or_comment');
  const count = bytes.readUInt16LE(end + 10), size = bytes.readUInt32LE(end + 12), start = bytes.readUInt32LE(end + 16);
  requireThat(count > 0 && count <= 32 && count === bytes.readUInt16LE(end + 8)
    && start + size === end, 'zip_directory');
  const entries = new Map();
  let pos = start, localEnd = 0, total = 0;
  for (let index = 0; index < count; index++) {
    requireThat(pos + 46 <= end && bytes.readUInt32LE(pos) === 0x02014b50, 'zip_central_header');
    const madeBy = bytes.readUInt16LE(pos + 4), version = bytes.readUInt16LE(pos + 6);
    const flags = bytes.readUInt16LE(pos + 8), method = bytes.readUInt16LE(pos + 10);
    const crc = bytes.readUInt32LE(pos + 16), packed = bytes.readUInt32LE(pos + 20), length = bytes.readUInt32LE(pos + 24);
    const nameLength = bytes.readUInt16LE(pos + 28), extra = bytes.readUInt16LE(pos + 30), comment = bytes.readUInt16LE(pos + 32);
    const attrs = bytes.readUInt32LE(pos + 38), offset = bytes.readUInt32LE(pos + 42);
    requireThat(version === 20 && [0, 0x800].includes(flags) && [0, 8].includes(method)
      && extra === 0 && comment === 0 && bytes.readUInt16LE(pos + 34) === 0
      && bytes.readUInt16LE(pos + 36) === 0, 'zip_unsupported_feature');
    requireThat((madeBy === 20 && attrs === 0) || (madeBy === 0x314 && attrs === 0x81a40000), 'zip_not_regular');
    requireThat(!(attrs & 0x10) && pos + 46 + nameLength <= end, 'zip_entry_type');
    const rawName = bytes.subarray(pos + 46, pos + 46 + nameLength);
    const name = new TextDecoder('utf-8', { fatal: true }).decode(rawName);
    requireThat(/^(?:[a-z0-9][a-z0-9_-]{0,31}\/)*[a-z0-9][a-z0-9_.-]{0,63}$/.test(name)
      && name.length <= 128 && !entries.has(name), 'zip_path');
    const cap = name === 'manifest.json' ? LIMITS.manifest : name === 'reports/omissions.json' ? LIMITS.omissions : LIMITS.entry;
    requireThat(length <= cap && (total += length) <= LIMITS.total, 'zip_expanded_limit');
    requireThat(offset === localEnd && offset + 30 + nameLength + packed <= start
      && bytes.readUInt32LE(offset) === 0x04034b50, 'zip_local_range');
    for (const [local, central, width] of [[4, 6, 2], [6, 8, 2], [8, 10, 2], [10, 12, 2],
      [12, 14, 2], [14, 16, 4], [18, 20, 4], [22, 24, 4], [26, 28, 2], [28, 30, 2]]) {
      requireThat(bytes.readUIntLE(offset + local, width) === bytes.readUIntLE(pos + central, width), 'zip_header_mismatch');
    }
    requireThat(rawName.equals(bytes.subarray(offset + 30, offset + 30 + nameLength)), 'zip_name_mismatch');
    const dataStart = offset + 30 + nameLength;
    const data = bytes.subarray(dataStart, dataStart + packed);
    let output;
    if (method === 0) output = data;
    else {
      const inflated = inflateRawSync(data, { maxOutputLength: Math.max(1, length), info: true });
      requireThat(inflated.engine.bytesWritten === packed, 'zip_deflate_trailing');
      output = inflated.buffer;
    }
    requireThat(output.length === length && crc32(output) === crc, 'zip_length_or_crc');
    entries.set(name, output);
    localEnd = dataStart + packed;
    pos += 46 + nameLength;
  }
  requireThat(pos === end && localEnd === start, 'zip_hidden_data');
  return entries;
}
