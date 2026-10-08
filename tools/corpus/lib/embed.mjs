// Local embedding runtime — transformers.js on the ONNX backend, no network
// after the first model fetch, no API key, nothing leaves the machine.

import { pipeline, env } from '@huggingface/transformers';

export const DEFAULT_MODEL = 'Xenova/bge-small-en-v1.5';

// bge-* asymmetric retrieval: passages are embedded bare, queries carry this
// instruction prefix. Skipping it measurably degrades recall.
const QUERY_PREFIX = 'Represent this sentence for searching relevant passages: ';

let cached = null;

export async function getEmbedder(model = DEFAULT_MODEL, { cacheDir } = {}) {
  if (cached && cached.model === model) return cached;
  if (cacheDir) env.cacheDir = cacheDir;
  const extract = await pipeline('feature-extraction', model, { dtype: 'q8' });
  const probe = await extract(['dimension probe'], { pooling: 'mean', normalize: true });
  cached = { model, extract, dim: probe.dims[1] };
  return cached;
}

/** Embed passages in batches. onProgress(done, total) for long indexing runs. */
export async function embedPassages(emb, texts, { batchSize = 16, onProgress } = {}) {
  const out = [];
  for (let i = 0; i < texts.length; i += batchSize) {
    const batch = texts.slice(i, i + batchSize);
    const t = await emb.extract(batch, { pooling: 'mean', normalize: true });
    for (let j = 0; j < batch.length; j++) {
      out.push(t.data.slice(j * emb.dim, (j + 1) * emb.dim));
    }
    onProgress?.(Math.min(i + batchSize, texts.length), texts.length);
  }
  return out;
}

export async function embedQuery(emb, query) {
  const t = await emb.extract([QUERY_PREFIX + query], { pooling: 'mean', normalize: true });
  return t.data.slice(0, emb.dim);
}
