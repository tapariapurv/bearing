// Daily email job (Vercel cron). Picks at most one email per person, sends through Gmail, logs to PostHog.
// Env: CRON_SECRET (Vercel sends it), GMAIL_USER, GMAIL_APP_PASSWORD, MAIL_SECRET, optional MAIL_FROM ("Purv <you@gmail.com>").
// Dry run unless MAIL_LIVE=1 and GMAIL_APP_PASSWORD is set. ?dry=1 lists who would get what without sending.
import nodemailer from 'nodemailer'
import { PostHog } from 'posthog-node'
import { list, mailState, setMailState } from './mcp.js'
import { pick, render, hash } from '../mail.js'

export default async function handler(req, res) {
  if (!process.env.CRON_SECRET || req.headers.authorization !== `Bearer ${process.env.CRON_SECRET}`) return res.status(401).end()
  const dry = req.query.dry === '1' || process.env.MAIL_LIVE !== '1' || !process.env.GMAIL_APP_PASSWORD, now = Date.now(), out = []
  const gmail = !dry && nodemailer.createTransport({ service: 'gmail', pool: true, auth: { user: process.env.GMAIL_USER, pass: process.env.GMAIL_APP_PASSWORD.replace(/\s/g, '') } })
  const ph = process.env.POSTHOG_API_KEY && new PostHog(process.env.POSTHOG_API_KEY, { host: process.env.POSTHOG_HOST, flushAt: 20, flushInterval: 0 })
  for (const u of await list()) {
    if (!u.email.includes('@')) continue
    const st = await mailState(u.email), kind = pick(u, st, now)
    if (!kind) continue
    if (dry) { out.push({ kind }); continue }
    const m = render(kind, u, now)
    const ok = await gmail.sendMail({ from: process.env.MAIL_FROM || `Purv <${process.env.GMAIL_USER}>`, to: u.email, subject: m.subject, html: m.html,
      list: { unsubscribe: { url: m.unsub, comment: 'Unsubscribe' } }, headers: { 'List-Unsubscribe-Post': 'List-Unsubscribe=One-Click' } }).then(() => true, () => false)
    out.push({ kind, ok })
    if (!ok) continue
    await setMailState(u.email, { ...st, [kind]: now, last: now, ...(kind === 'inactive' && { inactiveCount: (st.inactiveCount || 0) + 1 }) })
    ph?.capture({ distinctId: hash(u.email), event: 'email_sent', properties: { kind } })
  }
  gmail && gmail.close()
  await ph?.shutdown()
  console.log('email job', JSON.stringify({ dry, sent: out })) // readable in Vercel logs
  res.json({ dry, sent: out })
}
