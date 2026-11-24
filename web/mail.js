// Bearing emails: who gets what (pick) and what it says (render). Pure functions; api/email.js sends them.
import crypto from 'node:crypto'
import * as C from './core.js'

export const BASE = 'https://bearing-planner.vercel.app'
const DAY = 864e5
const esc = s => String(s ?? '').replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c])

// Signed per-person token for tracking and unsubscribe links: <email base64url>.<hmac>
const sig = e => crypto.createHmac('sha256', process.env.MAIL_SECRET || '').update(e).digest('base64url').slice(0, 22)
export const token = e => `${Buffer.from(e).toString('base64url')}.${sig(e)}`
export function who(t = '') {
  const [a, b] = String(t).split('.'), e = a && Buffer.from(a, 'base64url').toString()
  return e && b && process.env.MAIL_SECRET && b.length === 22 && crypto.timingSafeEqual(Buffer.from(b), Buffer.from(sig(e))) ? e : null
}
export const hash = e => crypto.createHash('sha256').update(e).digest('hex') // same distinctId as api/ai.js

// One email per person per day at most, most useful first. st is their row in the mail collection.
export function pick(u, st, now = Date.now()) {
  const p = u.data.prefs || {}, since = k => now - (st[k] || 0)
  if (st.off) return null
  if (!st.welcome && now - Date.parse(u.created) < 7 * DAY) return 'welcome'
  if (since('last') < 20 * 3600e3) return null
  if (p.emailTasks && open(u.data, now).length) return 'tasks'
  if (p.emailGoals && new Date(now).getUTCDay() === 0 && since('goals') > 6 * DAY && goals(u.data, now).length) return 'goals'
  if (p.emailNews !== false && now - u.modified > 5 * DAY && since('inactive') > 14 * DAY && (st.inactiveCount || 0) < 3) return 'inactive'
  return null
}

const endOfDay = now => { const d = new Date(now); d.setUTCHours(23, 59, 59); return d }
export const open = (d, now) => d.tasks.filter(t => !t.done && t.due && new Date(t.due) <= endOfDay(now)).sort((a, b) => a.due < b.due ? -1 : 1)
function goals(d, now) {
  const mon = new Date(now); mon.setUTCHours(0, 0, 0, 0); mon.setUTCDate(mon.getUTCDate() - (mon.getUTCDay() + 6) % 7)
  return C.goals(d).filter(g => g.weeklyHours > 0).map(g => ({ title: g.title, done: C.focused(d, g.id, mon) / 3600, want: g.weeklyHours }))
}
const first = u => (u.data.prefs?.profile?.name || '').split(' ')[0] || 'there'
const hrs = h => (Math.round(h * 10) / 10).toString()

// Each returns { subject, preview, body (paragraph HTML), cta: [label, page] }
const T = {
  welcome: u => ({ subject: 'Welcome to Bearing', preview: 'One thing to do first, and a way to reach me.',
    body: `<p>Hi ${esc(first(u))},</p><p>Thanks for giving Bearing a try. I built it because my weeks kept filling up with things that didn't matter, and I wanted something that would point that out.</p>
      <p>If you only do one thing today: add a goal or two and give each a few hours a week. Then hit <b>Plan with Coach</b> on the Today page and let it find the time.</p>
      <p>If something feels off or confusing, just reply to this email. It comes straight to me.</p>`, cta: ['Open Bearing', 'today'] }),
  inactive: (u, now) => {
    const g = C.goals(u.data)[0], days = Math.round((now - u.modified) / DAY)
    return { subject: g ? `Still working on ${g.title}?` : 'Got five minutes?', preview: `It's been ${days} days. Here's an easy way back in.`,
      body: `<p>Hi ${esc(first(u))},</p><p>You haven't opened Bearing in ${days} days. No guilt, weeks get away from everyone.</p>
        <p>${g ? `You said you wanted to spend time on <b>${esc(g.title)}</b>. One 25 minute session today is a good restart.` : 'Planning just tomorrow takes about two minutes, and it makes the day go better.'}</p>`,
      cta: [g ? 'Start a session' : 'Plan tomorrow', g ? 'focus' : 'today'] }
  },
  tasks: (u, now) => {
    const ts = open(u.data, now), n = ts.length, late = t => new Date(t.due) < new Date(C.dayKey(new Date(now)))
    return { subject: n === 1 ? `Still open: ${ts[0].title}` : `${n} things still open today`, preview: ts.slice(0, 3).map(t => t.title).join(', '),
      body: `<p>Hi ${esc(first(u))}, here's what's still open:</p><ul style="padding-left:20px;margin:0 0 16px">${ts.slice(0, 8).map(t => `<li style="margin:6px 0">${esc(t.title)}${late(t) ? ' <span style="color:#B4533E">· overdue</span>' : ''}</li>`).join('')}</ul>${n > 8 ? `<p style="color:#6B7280">and ${n - 8} more.</p>` : ''}
        <p>Pick one and get it done before tonight.</p>`, cta: ['Open my tasks', 'tasks'] }
  },
  goals: (u, now) => {
    const gs = goals(u.data, now), done = gs.reduce((a, g) => a + g.done, 0), want = gs.reduce((a, g) => a + g.want, 0)
    const best = [...gs].sort((a, b) => b.done - a.done)[0]
    const bar = g => { const w = Math.min(100, Math.round(g.done / g.want * 100)); return `<tr><td style="padding:8px 0">${esc(g.title)}</td><td style="padding:8px 0;text-align:right;color:#6B7280;white-space:nowrap">${hrs(g.done)} of ${g.want} h</td></tr><tr><td colspan="2"><div style="height:6px;border-radius:3px;background:#E3F2EC"><div style="height:6px;border-radius:3px;width:${w}%;background:#2E9E74"></div></div></td></tr>` }
    return { subject: `Your week: ${hrs(done)} of ${want} hours on your goals`, preview: best?.done ? `Most of it went to ${best.title}.` : 'A fresh week starts tomorrow.',
      body: `<p>Hi ${esc(first(u))}, here's how your week went.</p><table width="100%" style="border-collapse:collapse;margin:0 0 18px">${gs.map(bar).join('')}</table>
        <p>${best?.done ? `Most of your time went to <b>${esc(best.title)}</b>.` : 'Nothing logged this week. That happens.'} Ten minutes planning next week makes it much more likely to go the way you want.</p>`,
      cta: ['Plan next week', 'week'] }
  }
}

export function render(kind, u, now = Date.now()) {
  const m = T[kind](u, now), t = token(u.email), q = `u=${t}&k=${kind}`
  const go = `${BASE}/api/e?e=click&${q}&to=${m.cta[1]}`, unsub = `${BASE}/api/e?e=unsub&${q}`
  const why = kind === 'tasks' || kind === 'goals' ? 'You turned this on in Bearing › Settings › Accounts.' : 'You get this because you signed in to Bearing.'
  const html = `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width"><meta name="color-scheme" content="light"></head>
<body style="margin:0;background:#F6F8F7;font:16px/1.6 -apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif;color:#141716">
<div style="display:none;max-height:0;overflow:hidden">${esc(m.preview)}</div>
<table width="100%" cellpadding="0" cellspacing="0"><tr><td align="center" style="padding:32px 16px">
<table width="100%" cellpadding="0" cellspacing="0" style="max-width:520px;background:#fff;border-radius:16px;border:1px solid #E3E8E5"><tr><td style="padding:32px">
<img src="${BASE}/icon.png" width="36" height="36" alt="Bearing" style="border-radius:9px;margin-bottom:20px">
${m.body}
<p style="margin:26px 0"><a href="${go}" style="display:inline-block;background:#2E9E74;color:#fff;text-decoration:none;font-weight:600;padding:12px 24px;border-radius:999px">${m.cta[0]}</a></p>
<p style="margin:0">Purv</p>
</td></tr></table>
<p style="font-size:12px;color:#8A938F;max-width:520px;margin:18px auto 0">${why} <a href="${unsub}" style="color:#8A938F">Unsubscribe</a></p>
<img src="${BASE}/api/e?e=open&${q}" width="1" height="1" alt="">
</td></tr></table></body></html>`
  return { subject: m.subject, html, unsub }
}
