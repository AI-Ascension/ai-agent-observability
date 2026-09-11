// All normal tracking ingestion stays on the existing loopback Collector path.
export function collectorEndpoint(value) {
  const url = new URL(value);
  if (url.protocol !== 'http:' || !['127.0.0.1', '[::1]'].includes(url.hostname)
    || url.username || url.password || url.search || url.hash || url.pathname !== '/v1/traces') {
    throw new Error('collector_endpoint_must_be_loopback');
  }
  return url.href;
}

export async function deliver(store, runId, semanticDigest, target) {
  const endpoint = collectorEndpoint(target);
  let acknowledgedParts = 0;
  for (;;) {
    const row = store.claim(runId, semanticDigest, endpoint);
    if (!row) return { delivery: 'collector_acknowledged', acknowledgedParts,
      backendPersistence: 'unverified' };
    try {
      const response = await fetch(endpoint, { method: 'POST', redirect: 'error',
        signal: AbortSignal.timeout(10000), headers: { 'Content-Type': 'application/json' }, body: row.body });
      if (response.status !== 200 || !/^application\/json(?:;|$)/i.test(response.headers.get('content-type') ?? '')) {
        await response.body?.cancel();
        throw new Error('invalid_collector_response');
      }
      let bytes = 0;
      const chunks = [];
      for await (const chunk of response.body) {
        bytes += chunk.length;
        if (bytes > 16384) throw new Error('collector_response_limit');
        chunks.push(chunk);
      }
      const body = JSON.parse(Buffer.concat(chunks).toString('utf8'));
      if (!body || typeof body !== 'object' || Array.isArray(body)) throw new Error('invalid_collector_response');
      const partial = body.partialSuccess;
      if (partial !== undefined && (!partial || typeof partial !== 'object' || Array.isArray(partial)
        || ![undefined, 0, '0'].includes(partial.rejectedSpans)
        || ![undefined, ''].includes(partial.errorMessage))) throw new Error('collector_partial_success');
      store.settle(row, 'acknowledged');
      acknowledgedParts++;
    } catch {
      // Includes disconnect after successful remote receipt: never blindly resend.
      store.settle(row, 'unknown');
      throw new Error('delivery_reconciliation_required');
    }
  }
}
