// Daily email job (Vercel cron). Picks at most one email per person, sends through Resend, logs to PostHog.
// Env: CRON_SECRET (Vercel sends it), RESEND_API_KEY, MAIL_FROM, MAIL_SECRET. No RESEND_API_KEY = dry run.
// ?dry=1 lists who would get what without sending.
import { PostHog } from 'posthog-node'
import { list, mailState, setMailState } from './mcp.js'
import { pick, render, hash } from '../mail.js'

export default async function handler(req, res) {
  if (!process.env.CRON_SECRET || req.headers.authorization !== `Bearer ${process.env.CRON_SECRET}`) return res.status(401).end()
  const dry = req.query.dry === '1' || !process.env.RESEND_API_KEY, now = Date.now(), out = []
  const ph = process.env.POSTHOG_API_KEY && new PostHog(process.env.POSTHOG_API_KEY, { host: process.env.POSTHOG_HOST, flushAt: 20, flushInterval: 0 })
  for (const u of await list()) {
    if (!u.email.includes('@')) continue
    const st = await mailState(u.email), kind = pick(u, st, now)
    if (!kind) continue
    if (dry) { out.push({ kind }); continue }
    const m = render(kind, u, now)
    const r = await fetch('https://api.resend.com/emails', { method: 'POST', headers: { authorization: `Bearer ${process.env.RESEND_API_KEY}`, 'content-type': 'application/json' },
      body: JSON.stringify({ from: process.env.MAIL_FROM, to: u.email, subject: m.subject, html: m.html, headers: { 'List-Unsubscribe': `<${m.unsub}>`, 'List-Unsubscribe-Post': 'List-Unsubscribe=One-Click' } }) })
    out.push({ kind, ok: r.ok })
    if (!r.ok) continue
    await setMailState(u.email, { ...st, [kind]: now, last: now, ...(kind === 'inactive' && { inactiveCount: (st.inactiveCount || 0) + 1 }) })
    ph?.capture({ distinctId: hash(u.email), event: 'email_sent', properties: { kind } })
  }
  await ph?.shutdown()
  res.json({ dry, sent: out })
}
