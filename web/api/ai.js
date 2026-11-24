// Bearing AI: an OpenAI-compatible endpoint that needs no API key from the user.
// Signs in with the web key, then streams from Vercel AI Gateway. The function only pipes bytes,
// so it spends almost no Fluid CPU while the model is thinking.
import crypto from 'node:crypto'
import { PostHog } from 'posthog-node'
import { account } from './mcp.js'

const posthogKey = process.env.POSTHOG_API_KEY
const posthogHost = process.env.POSTHOG_HOST
const posthog = posthogKey && posthogHost ? new PostHog(posthogKey, { host: posthogHost, flushAt: 1, flushInterval: 0 }) : null
if (!posthog && process.env.NODE_ENV !== 'production') {
  const missing = posthogKey ? 'POSTHOG_HOST' : 'POSTHOG_API_KEY'
  console.warn(`${missing} variable required by PostHog is missing or un-configured, this causes events to be silently missed. This error stops appearing once ${missing} is configured`)
}

export const MODELS = ['anthropic/claude-haiku-5.5', 'anthropic/claude-sonnet-5.5', 'anthropic/claude-opus-5.5']

export default async function handler(req, res) {
  const a = await account(req, 'webKey').catch(() => null)
  if (!a) return res.status(401).json({ error: { message: 'Sign in again: open Bearing › Settings › Open on the Web once.' } })
  if (req.method === 'GET') return res.json({ data: MODELS.map(id => ({ id })) })
  if (req.method !== 'POST') return res.status(405).end()
  const b = req.body || {}
  const model = MODELS.includes(b.model) ? b.model : MODELS[0]
  const messages = (b.messages || []).slice(-40)
  const isStreaming = b.stream !== false
  const traceId = crypto.randomUUID()
  const sessionId = typeof b.aiSessionId === 'string' && /^[A-Za-z0-9_~.@()!':|-]+$/.test(b.aiSessionId) ? b.aiSessionId : null
  const distinctId = crypto.createHash('sha256').update(a.email).digest('hex')
  const startedAt = Date.now()
  const token = req.headers['x-vercel-oidc-token'] || process.env.VERCEL_OIDC_TOKEN || process.env.AI_GATEWAY_API_KEY
  const up = await fetch('https://ai-gateway.vercel.sh/v1/chat/completions', {
    method: 'POST',
    headers: { 'content-type': 'application/json', authorization: `Bearer ${token}` },
    body: JSON.stringify({
      model,
      messages,
      max_tokens: Math.min(b.max_tokens || 2048, 4096),
      stream: isStreaming,
    }),
  })
  res.status(up.status).setHeader('content-type', up.headers.get('content-type') || 'text/event-stream')
  res.setHeader('cache-control', 'no-store')
  const decoder = new TextDecoder()
  let body = '', bufferedLine = '', output = ''
  for await (const chunk of up.body) {
    res.write(chunk)
    const text = decoder.decode(chunk, { stream: true })
    if (!isStreaming) { body += text; continue }
    bufferedLine += text
    const lines = bufferedLine.split('\n')
    bufferedLine = lines.pop()
    for (const line of lines) {
      if (!line.startsWith('data: ') || line === 'data: [DONE]') continue
      try {
        const content = JSON.parse(line.slice(6)).choices?.[0]?.delta?.content
        if (content) output += content
      } catch {}
    }
  }
  res.end()
  let response
  if (!isStreaming) {
    try { response = JSON.parse(body); output = response.choices?.[0]?.message?.content || '' } catch {}
  }
  try {
    posthog?.capture({
      distinctId,
      event: '$ai_generation',
      properties: {
        $ai_trace_id: traceId,
        $ai_session_id: sessionId,
        $ai_model: model,
        $ai_provider: 'anthropic',
        $ai_latency: (Date.now() - startedAt) / 1000,
        $ai_http_status: up.status,
        $ai_stream: isStreaming,
        ...(response?.usage?.prompt_tokens != null && { $ai_input_tokens: response.usage.prompt_tokens }),
        ...(response?.usage?.completion_tokens != null && { $ai_output_tokens: response.usage.completion_tokens }),
        ...(!up.ok && { $ai_is_error: true }),
      },
    })
    await posthog?.flush()
  } catch {}
}
