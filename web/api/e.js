// Event endpoint: landing-page downloads, email opens, clicks, and unsubscribes. Logs to PostHog, then
// redirects to a fixed target only (no open redirect).
import { PostHog } from 'posthog-node'
import { who, hash } from '../mail.js'
import { mailState, setMailState } from './mcp.js'

const DMG = 'https://github.com/tapariapurv/bearing/releases/latest/download/Bearing.dmg'
const PAGES = ['today', 'tasks', 'week', 'focus', 'goals', 'coach']
const GIF = Buffer.from('R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7', 'base64')

export default async function handler(req, res) {
  const { e = '', k = '', src = '', to = '' } = req.query, email = who(req.query.u)
  const known = { download: 1, open: 1, click: 1, unsub: 1 }
  if (!known[e] || (e !== 'download' && !email)) return res.status(404).end()
  if (process.env.POSTHOG_API_KEY) {
    const ph = new PostHog(process.env.POSTHOG_API_KEY, { host: process.env.POSTHOG_HOST, flushAt: 1, flushInterval: 0 })
    ph.capture(email ? { distinctId: hash(email), event: `email_${e}`, properties: { kind: String(k).slice(0, 16), to: String(to).slice(0, 16) } }
      : { distinctId: 'anon', event: 'download', properties: { src: String(src).slice(0, 32), $process_person_profile: false } })
    await ph.shutdown().catch(() => {})
  }
  if (e === 'download') return res.redirect(302, DMG)
  if (e === 'open') { res.setHeader('content-type', 'image/gif'); res.setHeader('cache-control', 'no-store'); return res.end(GIF) }
  // ponytail: bearing:// opens the app if installed; no fallback page when it isn't
  if (e === 'click') return res.redirect(302, `bearing://${PAGES.includes(to) ? to : 'today'}`)
  await setMailState(email, { ...(await mailState(email)), off: true })
  res.setHeader('content-type', 'text/html; charset=utf-8')
  res.end(`<!doctype html><meta name="viewport" content="width=device-width"><body style="font:17px/1.5 -apple-system,system-ui,sans-serif;display:grid;place-items:center;height:90vh;margin:0;color:#141716;background:#F6F8F7"><p>You're unsubscribed. You won't get any more emails from Bearing.</p>`)
}
