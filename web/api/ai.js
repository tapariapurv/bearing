// Bearing AI: an OpenAI-compatible endpoint that needs no API key from the user.
// Signs in with the web key, then streams from Vercel AI Gateway. The function only pipes bytes,
// so it spends almost no Fluid CPU while the model is thinking.
import { account } from './mcp.js'

export const MODELS = ['anthropic/claude-haiku-5.5', 'anthropic/claude-sonnet-5.5', 'anthropic/claude-opus-5.5']

export default async function handler(req, res) {
  const a = await account(req, 'webKey').catch(() => null)
  if (!a) return res.status(401).json({ error: { message: 'Sign in again: open Bearing › Settings › Open on the Web once.' } })
  if (req.method === 'GET') return res.json({ data: MODELS.map(id => ({ id })) })
  if (req.method !== 'POST') return res.status(405).end()
  const b = req.body || {}
  const token = req.headers['x-vercel-oidc-token'] || process.env.VERCEL_OIDC_TOKEN || process.env.AI_GATEWAY_API_KEY
  const up = await fetch('https://ai-gateway.vercel.sh/v1/chat/completions', {
    method: 'POST',
    headers: { 'content-type': 'application/json', authorization: `Bearer ${token}` },
    body: JSON.stringify({
      model: MODELS.includes(b.model) ? b.model : MODELS[0],
      messages: (b.messages || []).slice(-40),
      max_tokens: Math.min(b.max_tokens || 2048, 4096),
      stream: b.stream !== false,
    }),
  })
  res.status(up.status).setHeader('content-type', up.headers.get('content-type') || 'text/event-stream')
  res.setHeader('cache-control', 'no-store')
  for await (const chunk of up.body) res.write(chunk)
  res.end()
}
