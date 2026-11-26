import {test} from 'node:test';
import assert from 'node:assert/strict';
import {ImportStore} from '../deploy/recorded-run/store.mjs';
import {deliver} from '../deploy/recorded-run/delivery.mjs';
const endpoint='http://127.0.0.1:4318/v1/traces';
function setup(t){
  const store=new ImportStore(':memory:');
  t.after(()=>store.close());
  const receipt=store.stage({identity:{namespace:'test',value:'binding'},semanticDigest:'a'.repeat(64)},()=>[{part:0},{part:1},{part:2}]);
  const claim=()=>store.claim(receipt.runId,receipt.semanticDigest,endpoint);
  const state=()=>store.db.prepare('SELECT part,state,endpoint FROM outbox ORDER BY part').all();
  return {store,claim,state,receipt};
}
for(const [label,sql] of [
  ['acknowledged row without collector binding',"UPDATE outbox SET state='acknowledged' WHERE part=0"],
  ['acknowledged row with empty collector binding',"UPDATE outbox SET state='acknowledged',endpoint='' WHERE part=0"],
  ['pending row pre-bound to requested collector',`UPDATE outbox SET endpoint='${endpoint}' WHERE part=0`],
  ['pending row with empty collector binding',"UPDATE outbox SET endpoint='' WHERE part=0"],
  ['acknowledged suffix before pending prefix',`UPDATE outbox SET state='acknowledged',endpoint='${endpoint}' WHERE part=2`],
]){
  test(`refuses ${label} without claiming a row`,t=>{
    const {store,claim,state}=setup(t);store.db.exec(sql);const before=state();
    assert.throws(claim,/delivery_state_integrity_conflict/);assert.deepEqual(state(),before);
  });
}
test('legitimate ordered acknowledged prefix resumes and completes',t=>{
  const {store,claim}=setup(t);for(let i=0;i<3;i++){const row=claim();assert.equal(row.part,i);store.settle(row,'acknowledged');}assert.equal(claim(),undefined);
});
test('uncertain sending claim remains reconciliation-required',t=>{const {claim}=setup(t);claim();assert.throws(claim,/delivery_reconciliation_required/);});
test('different bound collector still conflicts',t=>{const {store,claim}=setup(t);store.db.exec("UPDATE outbox SET state='acknowledged',endpoint='http://127.0.0.1:9999/v1/traces' WHERE part=0");assert.throws(claim,/endpoint_conflict/);});

test('delivery caller cannot report already acknowledged for unbound rows',async t=>{
  const {store,receipt,state}=setup(t);store.db.exec("UPDATE outbox SET state='acknowledged'");
  const before=state();const fetch=t.mock.method(globalThis,'fetch',async()=>{throw Error('must not fetch');});
  await assert.rejects(deliver(store,receipt.runId,receipt.semanticDigest,endpoint),/delivery_state_integrity_conflict/);
  assert.equal(fetch.mock.callCount(),0);assert.deepEqual(state(),before);
});
test('delivery caller never sends a pre-bound pending row',async t=>{
  const {store,receipt,state}=setup(t);store.db.prepare('UPDATE outbox SET endpoint=? WHERE part=0').run(endpoint);
  const before=state();const fetch=t.mock.method(globalThis,'fetch',async()=>new Response('{}',{headers:{'content-type':'application/json'}}));
  await assert.rejects(deliver(store,receipt.runId,receipt.semanticDigest,endpoint),/delivery_state_integrity_conflict/);
  assert.equal(fetch.mock.callCount(),0);assert.deepEqual(state(),before);
});
