// Hosted Bearing MCP server (Streamable HTTP, JSON responses). Any device or server can reach it with the
// token from Bearing › Settings › Agents › Remote: bk_<email, base64url>_<secret>. It reads and writes the
// same Firestore document the apps sync, and obeys the user's synced permissions ("ask" counts as allow here: there is no one to ask).
import crypto from 'node:crypto'
import * as C from '../core.js'

const DOC = 'https://firestore.googleapis.com/v1/projects/bearing-514007/databases/(default)/documents/users/'
let cached = { token: '', exp: 0 }
export async function saToken() {
  if (cached.exp > Date.now() + 60000) return cached.token
  const sa = JSON.parse(process.env.GOOGLE_SA), now = Math.floor(Date.now() / 1000)
  const b = o => Buffer.from(JSON.stringify(o)).toString('base64url')
  const body = `${b({ alg: 'RS256', typ: 'JWT' })}.${b({ iss: sa.client_email, scope: 'https://www.googleapis.com/auth/datastore', aud: 'https://oauth2.googleapis.com/token', iat: now, exp: now + 3600 })}`
  const jwt = `${body}.${crypto.sign('RSA-SHA256', Buffer.from(body), sa.private_key).toString('base64url')}`
  const r = await (await fetch('https://oauth2.googleapis.com/token', { method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded' }, body: `grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=${jwt}` })).json()
  cached = { token: r.access_token, exp: Date.now() + r.expires_in * 1000 }; return cached.token
}
export async function load(email) {
  const r = await fetch(DOC + encodeURIComponent(email), { headers: { authorization: `Bearer ${await saToken()}` } })
  if (!r.ok) return null
  const doc = await r.json()
  return { data: C.fill(JSON.parse(doc.fields.data.stringValue)), updateTime: doc.updateTime }
}
// Every account, for the daily email job. ponytail: one page of 300; add pageToken paging past that.
export async function list() {
  const r = await (await fetch(DOC + '?pageSize=300', { headers: { authorization: `Bearer ${await saToken()}` } })).json()
  return (r.documents || []).map(d => ({ email: decodeURIComponent(d.name.split('/').pop()), created: d.createTime,
    modified: (d.fields.modified?.doubleValue ?? 0) * 1000, data: C.fill(JSON.parse(d.fields.data.stringValue)) }))
}
// Email state lives in its own collection so it never races the apps' whole-document sync.
const MAIL = DOC.replace('/users/', '/mail/')
export async function mailState(email) {
  const r = await fetch(MAIL + encodeURIComponent(email), { headers: { authorization: `Bearer ${await saToken()}` } })
  return r.ok ? JSON.parse((await r.json()).fields.s.stringValue) : {}
}
export async function setMailState(email, st) {
  await fetch(MAIL + encodeURIComponent(email), { method: 'PATCH', headers: { authorization: `Bearer ${await saToken()}`, 'content-type': 'application/json' },
    body: JSON.stringify({ fields: { s: { stringValue: JSON.stringify(st) } } }) })
}
export async function save(email, data, updateTime) {
  const u = `${DOC}${encodeURIComponent(email)}?updateMask.fieldPaths=data&updateMask.fieldPaths=modified&currentDocument.updateTime=${updateTime}`
  const r = await fetch(u, { method: 'PATCH', headers: { authorization: `Bearer ${await saToken()}`, 'content-type': 'application/json' },
    body: JSON.stringify({ fields: { data: { stringValue: JSON.stringify(data) }, modified: { doubleValue: Date.now() / 1000 } } }) })
  if (!r.ok) throw Object.assign(new Error(r.status === 400 || r.status === 409 || r.status === 412 ? 'Bearing changed at the same moment; try again.' : `Save failed (${r.status})`), { status: r.status })
}
export async function account(req, field = 'agentKey') { // webKey authorizes Bearing AI, agentKey agents
  // A header for clients that send one; ?key= for clients that only take a URL (ChatGPT, Gemini and other connector UIs).
  const m = /^Bearer bk_([A-Za-z0-9_-]+)_([a-f0-9]{64})$/.exec(req.headers.authorization || (req.query?.key ? `Bearer ${req.query.key}` : ''))
  if (!m) return null
  const email = Buffer.from(m[1], 'base64url').toString(), doc = await load(email), key = doc?.data.prefs[field] || ''
  if (key.length !== 64 || !crypto.timingSafeEqual(Buffer.from(key), Buffer.from(m[2]))) return null
  return { email, ...doc }
}

const s = description => ({ type: 'string', description })
const T = (name, scope, description, properties = {}, required = []) => ({ name, scope, description, inputSchema: { type: 'object', properties, required } })
export const TOOLS = [
  T('get_overview', 'read', 'Season goals, classes with their sub-projects, projects, and open task counts.'),
  T('list_tasks', 'read', 'List tasks, open ones by default.', { area: s('Class or project name'), sub_project: s('Sub-project'), goal: s('Goal title'), query: s('Text in the title'), due_before: s('YYYY-MM-DD, inclusive'), include_done: { type: 'boolean' } }),
  T('get_task', 'read', 'One task with every field.', { id: s('Task id') }, ['id']),
  T('list_goals', 'read', 'Season goals with why, metric, weekly hour target, status, notes and hours focused in the last 7 days.'),
  T('get_schedule', 'read', 'Time blocks with ids, day by day (calendar events stay on the user\'s devices).', { date: s('YYYY-MM-DD, default today'), days: { type: 'integer', description: '1 to 14' } }),
  T('get_journal', 'read', 'Journal entries between two dates.', { from: s('YYYY-MM-DD, default 7 days ago'), to: s('YYYY-MM-DD, default today') }),
  T('get_focus_stats', 'read', 'Focus sessions: hours, count, quality and distractions, per goal.', { days: { type: 'integer', description: 'Look back this many days, default 7' } }),
  T('search', 'read', 'Search tasks, goals, classes, projects and the journal.', { query: s('Words to find') }, ['query']),
  T('add_task', 'write', 'Add a task. It syncs to Todoist tagged with its class/project and sub-project.', { title: s('Task title'), area: s('Class or project name'), sub_project: s('Sub-project inside the class'), goal: s('Goal title'), due: s('YYYY-MM-DD'), priority: { type: 'integer', description: '1 normal to 4 urgent' }, notes: s('Details'), resources: { type: 'array', items: { type: 'string' } } }, ['title']),
  T('add_area', 'write', 'Create a class or a standalone project.', { name: s('Name'), kind: { type: 'string', enum: ['class', 'project'] }, goal: s('Optional season goal it serves') }, ['name', 'kind']),
  T('add_sub_project', 'write', 'Create a sub-project inside a class.', { class: s('Class name'), name: s('Sub-project name') }, ['class', 'name']),
  T('time_block', 'write', 'Block time for a task.', { id: s('Task id'), start: s('YYYY-MM-DDTHH:MM in the user\'s time; default the next free slot'), minutes: { type: 'integer' } }, ['id']),
  T('write_journal', 'write', 'Add to (or replace) a day\'s journal entry.', { text: s('Text'), date: s('YYYY-MM-DD, default today'), replace: { type: 'boolean' } }, ['text']),
  T('update_task', 'edit', 'Change a task. Only the fields you pass change; an empty string clears due, area, goal or sub_project.', { id: s('Task id'), title: s(''), area: s(''), sub_project: s(''), goal: s(''), due: s('YYYY-MM-DD'), priority: { type: 'integer' }, notes: s(''), add_resources: { type: 'array', items: { type: 'string' } } }, ['id']),
  T('complete_task', 'edit', 'Mark a task done (or not done with done=false).', { id: s('Task id'), done: { type: 'boolean' } }, ['id']),
  T('update_area', 'edit', 'Rename a class or project, switch its kind, or link it to a goal (empty goal unlinks).', { name: s('Current name'), new_name: s(''), kind: { type: 'string', enum: ['class', 'project'] }, goal: s('Goal title'), icon: s('SF Symbol name like book or graduationcap, empty clears'), color: s('Hex like #3FAE86'), status: { type: 'string', enum: ['priority', 'active', 'done', 'archived'] } }, ['name']),
  T('update_goal', 'edit', 'Change a goal\'s fields.', { title: s('Current title'), new_title: s(''), why: s(''), metric: s(''), notes: s('Next actions'), status: { type: 'string', enum: ['none', 'onTrack', 'adjust', 'offTrack'] }, weekly_hours: { type: 'number' } }, ['title']),
  T('delete_task', 'delete', 'Delete a task.', { id: s('Task id') }, ['id']),
  T('delete_area', 'delete', 'Remove a class or project. Its tasks stay, unsorted.', { name: s('Class or project name') }, ['name']),
  T('delete_block', 'delete', 'Remove a time block.', { id: s('Block id from get_schedule') }, ['id']),
]

// ponytail: times use the server's zone (UTC on Vercel) unless the agent passes the offset in start; add a tz pref if it matters.
export function run(d, name, a = {}) {
  const str = k => typeof a[k] === 'string' ? a[k].trim() : undefined
  const row = t => Object.fromEntries(Object.entries({ id: t.id, title: t.title, done: t.done, priority: t.priority, due: t.due && C.dayKey(t.due), area: C.areaName(d, t.areaID),
    sub_project: t.sub, goal: C.goalTitle(d, t.goalID), notes: t.notes || undefined, resources: t.resources?.length ? t.resources : undefined }).filter(([, v]) => v !== undefined))
  const open = d.tasks.filter(t => !t.done), id = () => C.task(d, str('id'))
  const h = x => Math.round(x / 360) / 10, ago = n => { const x = new Date(); x.setDate(x.getDate() - n); return x }
  switch (name) {
    case 'get_overview': {
      const ar = x => ({ name: x.name, goal: C.goalTitle(d, x.goal) || '', open_tasks: open.filter(t => t.areaID === x.id).length, ...(x.isClass && { sub_projects: x.subs || [] }) })
      return { today: C.dayKey(), goals: C.goals(d).map(g => ({ title: g.title, open_tasks: open.filter(t => t.goalID === g.id).length })),
        classes: d.areas.filter(x => x.isClass).map(ar), projects: d.areas.filter(x => !x.isClass).map(ar) }
    }
    case 'list_tasks': {
      const ar = str('area') && C.area(d, str('area')), g = str('goal') && C.goal(d, str('goal')), q = str('query')?.toLowerCase(), end = C.parseDay(str('due_before'))
      if (end) end.setDate(end.getDate() + 1)
      return d.tasks.filter(t => (a.include_done || !t.done) && (!ar || t.areaID === ar.id) && (!str('sub_project') || t.sub === str('sub_project')) && (!g || t.goalID === g.id)
        && (!end || (t.due && new Date(t.due) < end)) && (!q || t.title.toLowerCase().includes(q))).slice(0, 200).map(row)
    }
    case 'get_task': return row(id())
    case 'list_goals': return C.goals(d).map(g => ({ title: g.title, why: g.why, metric: g.metric, weekly_hours: g.weeklyHours, tier: g.level || 'core', status: g.status, notes: g.notes,
      focused_hours_7d: h(C.focused(d, g.id, ago(7))), open_tasks: open.filter(t => t.goalID === g.id).length }))
    case 'get_schedule': {
      const s0 = C.parseDay(str('date')) || new Date(new Date().setHours(0, 0, 0, 0)), e = new Date(s0); e.setDate(e.getDate() + Math.min(14, Math.max(1, a.days || 1)))
      return d.blocks.filter(b => new Date(b.start) >= s0 && new Date(b.start) < e).sort((x, y) => x.start < y.start ? -1 : 1).map(b => ({ id: b.id, title: b.title, start: b.start, end: b.end, goal: C.goalTitle(d, b.goalID) }))
    }
    case 'get_journal': {
      const to = str('to') || C.dayKey(), from = str('from') || C.dayKey(ago(7))
      return d.journal.filter(j => j.id >= from && j.id <= to).sort((x, y) => x.id < y.id ? -1 : 1).map(j => ({ date: j.id, prompt: j.prompt, text: j.text }))
    }
    case 'get_focus_stats': {
      const ss = d.sessions.filter(x => new Date(x.start) >= ago(a.days || 7))
      const sum = l => ({ hours: h(l.reduce((n, x) => n + x.seconds, 0)), sessions: l.length, distractions: l.reduce((n, x) => n + x.distractions, 0), avg_quality: l.length ? Math.round(l.reduce((n, x) => n + C.quality(x), 0) / l.length) : 0 })
      return { total: sum(ss), by_goal: Object.fromEntries([...new Set(ss.map(x => x.goalID))].map(g => [C.goalTitle(d, g) || 'No goal', sum(ss.filter(x => x.goalID === g))])) }
    }
    case 'search': {
      const q = str('query')?.toLowerCase(); if (!q) throw new Error('query is required')
      const has = (...v) => v.join(' ').toLowerCase().includes(q)
      return { tasks: d.tasks.filter(t => has(t.title, t.notes)).slice(0, 50).map(row), goals: C.goals(d).filter(g => has(g.title, g.why, g.notes)).map(g => g.title),
        areas: d.areas.filter(x => has(x.name, ...(x.subs || []))).map(x => x.name), journal: d.journal.filter(j => has(j.text)).map(j => ({ date: j.id, text: j.text.slice(0, 300) })) }
    }
    case 'add_task': {
      if (!str('title')) throw new Error('title is required')
      const ar = str('area') && C.area(d, str('area')), sub = str('sub_project') || undefined
      if (sub && !ar?.isClass) throw new Error('sub_project needs a class in area')
      const t = C.addTask(d, { title: str('title'), areaID: ar?.id, sub, goalID: str('goal') && C.goal(d, str('goal')).id, due: C.parseDay(str('due')), notes: str('notes') || '', priority: Math.min(4, Math.max(1, a.priority || 1)) })
      if (a.resources?.length) t.resources = a.resources
      return row(t)
    }
    case 'update_task': {
      const t = id(), ch = {}
      if (str('title')) ch.title = str('title')
      if (str('notes') !== undefined) ch.notes = str('notes')
      if (a.priority) ch.priority = Math.min(4, Math.max(1, a.priority))
      if (str('due') !== undefined) ch.due = C.parseDay(str('due'))
      if (str('area') !== undefined) { const x = str('area') && C.area(d, str('area')); ch.areaID = x?.id; if (!x?.isClass) ch.sub = null }
      if (str('sub_project') !== undefined) ch.sub = str('sub_project')
      if (str('goal') !== undefined) ch.goalID = str('goal') && C.goal(d, str('goal')).id
      C.updateTask(d, t, ch); if (a.add_resources?.length) t.resources = [...(t.resources || []), ...a.add_resources]
      return row(t)
    }
    case 'complete_task': { const t = id(); C.setDone(d, t, a.done ?? true); return row(t) }
    case 'delete_task': { const t = id(); C.deleteTask(d, t); return `Deleted ${t.title}` }
    case 'add_area': {
      if (!str('name')) throw new Error('name is required')
      if (d.areas.some(x => x.name.toLowerCase() === str('name').toLowerCase())) throw new Error(`${str('name')} already exists`)
      const x = { id: C.uuid(), name: str('name'), isClass: str('kind') !== 'project' }; d.areas.push(x)
      if (str('goal')) link(d, x, C.goal(d, str('goal')).id)
      return `Added ${x.isClass ? 'class' : 'project'} ${x.name}`
    }
    case 'add_sub_project': {
      const x = C.area(d, str('class') || ''); if (!x.isClass) throw new Error(`${x.name} is a project; sub-projects live in classes`)
      if (!str('name')) throw new Error('name is required')
      if (!(x.subs || []).includes(str('name'))) x.subs = [...(x.subs || []), str('name')]
      return `Added ${str('name')} to ${x.name}`
    }
    case 'update_area': {
      const x = C.area(d, str('name') || '')
      if (str('new_name')) x.name = str('new_name')
      if (str('kind')) { x.isClass = str('kind') !== 'project'; if (!x.isClass) delete x.subs }
      if (str('goal') !== undefined) link(d, x, str('goal') && C.goal(d, str('goal')).id)
      if (str('icon') !== undefined) x.icon = str('icon') || undefined
      if (str('color')) x.hex = str('color')
      const st = str('status'); if (st) Object.assign(x, { priority: st === 'priority', done: st === 'done', archived: st === 'archived' })
      if (str('new_name') || str('kind')) C.relabel(d, x)
      return `Updated ${x.name}`
    }
    case 'update_goal': {
      const g = C.goal(d, str('title') || '')
      if (str('new_title')) g.title = str('new_title')
      for (const k of ['why', 'metric', 'notes']) if (str(k) !== undefined) g[k] = str(k)
      if (str('status')) { if (!['none', 'onTrack', 'adjust', 'offTrack'].includes(str('status'))) throw new Error('Unknown status'); g.status = str('status') }
      if (typeof a.weekly_hours === 'number') g.weeklyHours = a.weekly_hours
      return `Updated ${g.title}`
    }
    case 'write_journal': { if (!str('text')) throw new Error('text is required'); const k = str('date') || C.dayKey(); C.parseDay(k); C.writeJournal(d, k, str('text'), a.replace); return `Saved the journal for ${k}` }
    case 'delete_area': { const x = C.area(d, str('name') || ''); d.areas = d.areas.filter(y => y !== x); return `Removed ${x.name}` }
    case 'delete_block': { const b = d.blocks.find(b => b.id === str('id')?.toUpperCase()); if (!b) throw new Error('No block with that id'); d.blocks = d.blocks.filter(x => x !== b); return `Removed ${b.title}` }
    case 'time_block': {
      const t = id(), m = a.minutes || d.prefs.blockMinutes || 60
      const start = str('start') ? new Date(str('start')) : C.nextFree(d, m)
      if (!start || isNaN(start)) throw new Error('Use YYYY-MM-DDTHH:MM')
      const b = C.addBlock(d, { title: t.title, start, minutes: m, goalID: t.goalID, taskID: t.id })
      return `Block ${b.id}: blocked ${m} min for ${t.title} at ${b.start}`
    }
  }
  throw new Error(`Unknown tool ${name}`)
}
function link(d, x, gid) { // same as Store.link(area:goal:): set the link and fill the goal on its tasks
  if (gid) x.goal = gid; else delete x.goal
  if (gid) for (const t of d.tasks) if (t.areaID === x.id && !t.goalID) t.goalID = gid
}

const VERSIONS = ['2025-11-25', '2025-06-18', '2025-03-26', '2024-11-05']
// One JSON-RPC message in, one response out (or null for notifications and client responses).
async function answer(m, d, acct) {
  if (!m || typeof m !== 'object' || m.jsonrpc !== '2.0' || typeof m.method !== 'string') return m?.id === undefined ? null : { jsonrpc: '2.0', id: m.id ?? null, error: { code: -32600, message: 'Invalid request' } }
  if (m.id === undefined) return null
  const ok = result => ({ jsonrpc: '2.0', id: m.id, result }), allowed = t => C.mode(d, t.scope) !== 'off'
  switch (m.method) {
    case 'initialize': return ok({ protocolVersion: VERSIONS.includes(m.params?.protocolVersion) ? m.params.protocolVersion : VERSIONS[0], capabilities: { tools: { listChanged: false } }, serverInfo: { name: 'bearing', title: 'Bearing', version: '2.3.0' },
      instructions: 'Bearing is a planner: season goals, classes (with sub-projects) and projects, tasks, time blocks, focus sessions and a journal. Call get_overview first for names.' })
    case 'ping': return ok({})
    case 'tools/list': return ok({ tools: TOOLS.filter(allowed).map(({ scope, ...t }) => ({ ...t, annotations: { readOnlyHint: scope === 'read', destructiveHint: false } })) })
    case 'tools/call': {
      const t = TOOLS.find(t => t.name === m.params?.name), reply = (text, isError = false) => ok({ content: [{ type: 'text', text }], isError })
      if (!t) return reply(`Unknown tool ${m.params?.name}`, true)
      if (!allowed(t)) return reply(`The user allows ${t.scope} only after asking, or not at all. Ask them to set ${t.scope} to Allow in Bearing › Settings › Agents.`, true)
      try {
        const out = run(d, t.name, m.params.arguments || {})
        if (t.scope !== 'read') { await save(acct.email, d, acct.updateTime); Object.assign(acct, await load(acct.email)) } // fresh updateTime for the next write in a batch
        return reply(typeof out === 'string' ? out : JSON.stringify(out))
      } catch (e) { return reply(e.message, true) }
    }
    case 'resources/list': return ok({ resources: [] })
    case 'prompts/list': return ok({ prompts: [] })
  }
  return { jsonrpc: '2.0', id: m.id, error: { code: -32601, message: `Unknown method ${m.method}` } }
}

// Streamable HTTP MCP (stateless, JSON responses). Works with any MCP client: Claude, ChatGPT, Codex, Gemini, Cursor, Grok and others.
export default async function handler(req, res) {
  res.setHeader('access-control-allow-origin', '*'); res.setHeader('access-control-allow-methods', 'POST, GET, OPTIONS')
  res.setHeader('access-control-allow-headers', 'authorization, content-type, accept, mcp-session-id, mcp-protocol-version, last-event-id'); res.setHeader('access-control-expose-headers', 'mcp-session-id, www-authenticate')
  if (req.method === 'OPTIONS') return res.status(204).end()
  if (req.method !== 'POST') return res.setHeader('allow', 'POST, OPTIONS').status(405).json({ error: 'POST JSON-RPC to this URL. No SSE stream is offered.' })
  let body = req.body
  if (typeof body === 'string') try { body = JSON.parse(body) } catch { return res.status(400).json({ jsonrpc: '2.0', id: null, error: { code: -32700, message: 'Parse error' } }) }
  const batch = Array.isArray(body), msgs = batch ? body : [body]
  if (msgs.every(m => m?.id === undefined)) return res.status(202).end() // notifications need no answer, so skip the Firestore read
  const acct = await account(req).catch(() => null)
  if (!acct) return res.setHeader('www-authenticate', 'Bearer realm="bearing", error="invalid_token"').status(401)
    .json({ jsonrpc: '2.0', id: msgs.find(m => m?.id !== undefined)?.id ?? null, error: { code: -32001, message: 'Bad token. Copy it from Bearing › Settings › Agents › Remote.' } })
  const out = []
  for (const m of msgs) { const r = await answer(m, acct.data, acct); if (r) out.push(r) }
  if (!out.length) return res.status(202).end()
  res.json(batch ? out : out[0])
}
