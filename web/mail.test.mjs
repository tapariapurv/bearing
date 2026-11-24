// node mail.test.mjs: checks who gets which email and writes previews to $OUT
import assert from 'node:assert'; import fs from 'node:fs'
process.env.MAIL_SECRET = 'test'
const { pick, render, token, who } = await import('./mail.js')
const now = Date.parse('2026-11-29T15:00:00Z'), D = 864e5 // a Sunday
const u = (prefs = {}, ago = 30, idle = 0) => ({ email: 'a@b.co', created: new Date(now - ago * D).toISOString(), modified: now - idle * D,
  data: { prefs: { profile: { name: 'Sam Lee' }, ...prefs }, goals: [{ id: 'G', title: 'Learn piano', weeklyHours: 5 }], areas: [], blocks: [], journal: [], outbox: [],
    sessions: [{ goalID: 'G', start: new Date(now - D).toISOString(), seconds: 7200, pausedSeconds: 0, distractions: 0 }],
    tasks: [{ id: '1', title: 'Write lab report', due: new Date(now - 2 * D).toISOString() }, { id: '2', title: 'Read chapter 5', due: new Date(now).toISOString() }] } })
assert.equal(pick(u({}, 2), {}, now), 'welcome')
assert.equal(pick(u({}, 2), { welcome: 1 }, now), null)
assert.equal(pick(u({ emailTasks: true }), {}, now), 'tasks')
assert.equal(pick(u({ emailTasks: true }), { last: now - 3600e3 }, now), null)
assert.equal(pick(u({ emailGoals: true }), {}, now), 'goals')
assert.equal(pick(u({}, 30, 6), {}, now), 'inactive')
assert.equal(pick(u({ emailNews: false }, 30, 6), {}, now), null)
assert.equal(pick(u({}, 30, 6), { off: true }, now), null)
assert.equal(who(token('a@b.co')), 'a@b.co'); assert.equal(who(token('a@b.co').slice(0, -1) + 'x'), null)
for (const k of ['welcome', 'inactive', 'tasks', 'goals']) { const m = render(k, u({}, 30, 6), now); process.env.OUT && fs.writeFileSync(`${process.env.OUT}/${k}.html`, m.html); console.log(k, '|', m.subject) }
console.log('ALL PASSED')
