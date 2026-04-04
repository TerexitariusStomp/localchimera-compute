import { TinyHumansMemoryClient } from '@tinyhumansai/neocortex';

// https://tinyhumans.ai/

const client = new TinyHumansMemoryClient({
  token: process.env.TINYHUMANS_TOKEN!,
});

await client.insertMemory({
  title: 'User preference',
  content: 'User prefers dark mode',
  namespace: 'preferences',
});

const query = await client.queryMemory({
  query: 'What does the user prefer?',
  namespace: 'preferences',
  maxChunks: 10,
});

console.log(query.data.response);