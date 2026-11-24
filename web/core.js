// Shared by the web app and the hosted MCP server (api/mcp.js). Works on the same AppData JSON the
// Mac and iPhone apps sync to Firestore, so every non-optional Swift field must be written.
export const uuid = () => crypto.randomUUID().toUpperCase()
export const iso = d => new Date(d).toISOString().replace(/\.\d{3}/, '')
export const dayKey = (d = new Date()) => { const x = new Date(d); return `${x.getFullYear()}-${String(x.getMonth() + 1).padStart(2, '0')}-${String(x.getDate()).padStart(2, '0')}` }
export const parseDay = s => { if (!s) return null; const m = /^(\d{4})-(\d\d)-(\d\d)$/.exec(s); if (!m) throw new Error(`Use YYYY-MM-DD, not ${s}`); return new Date(+m[1], m[2] - 1, +m[3]) }
const low = s => (s || '').toLowerCase()

export const SCOPES = [
  { key: 'read', title: 'Read', detail: 'Tasks, goals, classes, schedule, journal, focus stats, search', fallback: 'allow' },
  { key: 'write', title: 'Write', detail: 'Add tasks, classes, projects, time blocks and journal notes', fallback: 'ask' },
  { key: 'edit', title: 'Edit', detail: 'Change or complete tasks, rename classes, update goals', fallback: 'ask' },
  { key: 'delete', title: 'Delete', detail: 'Remove tasks, classes, projects and time blocks', fallback: 'ask' },
]
export const mode = (d, s) => d.prefs?.agentAccess?.[s] || SCOPES.find(x => x.key === s)?.fallback || 'off'

export function fill(d) { // missing arrays from very old data
  for (const k of ['goals', 'tasks', 'blocks', 'sessions', 'journal', 'outbox']) d[k] ||= []
  d.areas ||= []; d.prefs ||= {}; return d
}
export const goals = d => d.goals.filter(g => !g.archived)
export const area = (d, n) => { const a = d.areas.find(a => low(a.name) === low(n)); if (!a) throw new Error(`No class or project named ${n}`); return a }
export const goal = (d, n) => { const g = goals(d).find(g => low(g.title) === low(n)); if (!g) throw new Error(`No goal named ${n}`); return g }
export const task = (d, id) => { const t = d.tasks.find(t => t.id === id?.toUpperCase()); if (!t) throw new Error('No task with that id'); return t }
const labels = (d, t) => d.prefs.labelSync === false ? [] : [d.areas.find(a => a.id === t.areaID)?.name, t.sub].filter(Boolean)
function link(d, t) {
  const a = d.areas.find(a => a.id === t.areaID)
  if (!t.goalID && a?.goal) t.goalID = a.goal
  if (!t.areaID && t.goalID) { const b = d.areas.find(a => a.goal === t.goalID); if (b) t.areaID = b.id }
}
const cmd = (d, type, args, extra = {}) => d.todoistToken && d.outbox.push({ uuid: uuid(), type, args, ...extra })
export const relabel = (d, a) => d.tasks.filter(t => t.areaID === a.id && t.todoistID).forEach(t => cmd(d, 'item_update', { id: t.todoistID, labels: labels(d, t) }))

export function addTask(d, { title, goalID, areaID, sub, due, notes = '', priority = 1 }) {
  const t = { id: uuid(), title, notes, project: '', priority, done: false }
  if (goalID) t.goalID = goalID; if (areaID) t.areaID = areaID; if (sub) t.sub = sub; if (due) t.due = iso(due)
  link(d, t)
  if (d.todoistToken) {
    t.todoistID = uuid(); const a = { content: title }, l = labels(d, t)
    if (l.length) a.labels = l; if (due) a.due = { date: dayKey(due) }
    cmd(d, 'item_add', a, { tempID: t.todoistID, taskID: t.id })
  }
  d.tasks.push(t); return t
}
export function updateTask(d, t, ch) {
  const a = { id: t.todoistID }
  if (ch.title != null && ch.title !== t.title) a.content = t.title = ch.title
  if (ch.notes != null && ch.notes !== t.notes) a.description = t.notes = ch.notes
  if (ch.priority != null && ch.priority !== t.priority) a.priority = t.priority = ch.priority
  if (ch.due !== undefined) { if (ch.due) { t.due = iso(ch.due); a.due = { date: dayKey(ch.due) } } else { delete t.due; a.due = null } }
  if (ch.goalID !== undefined) ch.goalID ? t.goalID = ch.goalID : delete t.goalID
  if (ch.areaID !== undefined) ch.areaID ? t.areaID = ch.areaID : delete t.areaID
  if (ch.sub !== undefined) ch.sub ? t.sub = ch.sub : delete t.sub
  link(d, t)
  if (ch.areaID !== undefined || ch.sub !== undefined) a.labels = labels(d, t)
  if (t.todoistID && Object.keys(a).length > 1) cmd(d, 'item_update', a)
  return t
}
export function setDone(d, t, done = !t.done) { t.done = done; done ? t.doneAt = iso(new Date()) : delete t.doneAt; if (t.todoistID) cmd(d, done ? 'item_close' : 'item_uncomplete', { id: t.todoistID }) }
export function deleteTask(d, t) { d.tasks = d.tasks.filter(x => x !== t); if (t.todoistID) cmd(d, 'item_delete', { id: t.todoistID }) }
export function addBlock(d, { title, start, minutes, goalID, taskID }) {
  const b = { id: uuid(), title, start: iso(start), end: iso(+new Date(start) + minutes * 60000) }
  if (goalID) b.goalID = goalID; if (taskID) b.taskID = taskID
  d.blocks.push(b); return b
}
export function nextFree(d, minutes, from = new Date()) {
  const p = d.prefs, day = new Date(from); day.setHours(0, 0, 0, 0)
  for (let i = 0; i < 14; i++, day.setDate(day.getDate() + 1)) {
    const s = new Date(day).setHours(p.dayStart ?? 9), e = new Date(day).setHours(p.dayEnd ?? 19)
    let t = Math.max(s, Math.ceil(+from / 900000) * 900000)
    const busy = d.blocks.map(b => [+new Date(b.start), +new Date(b.end)]).filter(([a, b]) => b > s && a < e).sort((x, y) => x[0] - y[0])
    for (const [a, b] of busy) { if (a - t >= minutes * 60000) break; t = Math.max(t, b) }
    if (e - t >= minutes * 60000) return new Date(t)
  }
  return null
}
export const focused = (d, gid, since) => d.sessions.filter(s => s.goalID === gid && new Date(s.start) >= since).reduce((a, s) => a + s.seconds, 0)
export const quality = s => { if (!(s.seconds > 0)) return 0; return Math.max(0, Math.round(s.seconds / (s.seconds + s.pausedSeconds) * 100) - s.distractions * 5) }
export function writeJournal(d, k, text, replace) {
  const e = d.journal.find(j => j.id === k)
  if (e) e.text = replace ? text : [e.text, text].filter(Boolean).join('\n\n'); else d.journal.push({ id: k, prompt: '', text })
}
export const areaName = (d, id) => d.areas.find(a => a.id === id)?.name
export const goalTitle = (d, id) => d.goals.find(g => g.id === id)?.title
