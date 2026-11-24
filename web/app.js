// Bearing on the web: the Mac app's layout and features, minus what a browser can't do (local models, voice,
// site blocking, Calendar and Todoist calls). Reads and writes the same synced document through /api/data;
// the coach runs on Claude through /api/ai.
import { html, render, useState, useEffect, useRef } from 'https://esm.sh/htm@3.1.1/preact/standalone'
import * as C from './core.js'

const MODES = [['Day', 'Day'], ['Week', 'Week'], ['Month', 'Month'], ['Focus', 'Focus'], ['Projects', 'Projects'], ['Goals', 'Goals'], ['Coach', 'Coach'], ['Journal', 'Journal'], ['Insights', 'Stats']]
const PAL = ['#38BDF8', '#EF4444', '#14B8A6', '#E5409F', '#3FAE86', '#84CC16', '#F59E0B', '#64748B']
const PALN = ['Sky', 'Coral', 'Teal', 'Pink', 'Green', 'Lime', 'Amber', 'Slate']
const clock = d => new Date(d).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', hour12: false })
const dayName = d => new Date(d).toLocaleDateString([], { weekday: 'long', month: 'short', day: 'numeric' })
const sameDay = (a, b) => C.dayKey(a) === C.dayKey(b)
const addDays = (d, n) => { const x = new Date(d); x.setDate(x.getDate() + n); return x }
const dur = s => { const m = Math.round(s / 60); return m >= 60 ? `${Math.floor(m / 60)}h ${m % 60}m` : `${m}m` }
const ls = (k, v) => { try { if (v === undefined) return JSON.parse(localStorage.getItem(k)); localStorage.setItem(k, JSON.stringify(v)) } catch { return null } }
// The Mac app opens /#t=<web token>; the token lives in this browser only (a URL fragment never reaches a server).
if (location.hash.startsWith('#t=')) { ls('token', location.hash.slice(3)); history.replaceState(null, '', '/') }

// ---- Sync ----
let user, data, rev, rerender = () => {}, busy = 0
const auth = () => ({ authorization: `Bearer ${ls('token')}`, 'content-type': 'application/json' })
const api = (method, body) => fetch('/api/data', { method, headers: auth(), body: body && JSON.stringify(body) })
  .then(async r => { const j = await r.json(); if (r.status === 401) { ls('token', null); user = null } else if (j.data) { user = { email: j.email || user?.email }; data = C.fill(j.data); rev = j.updateTime }
    else if (!r.ok) data = { error: j.error }; rerender(); return r.status })
const pull = () => ls('token') && !busy && !document.hidden && api('GET').catch(() => {})
let queue = Promise.resolve()
function save(fn) { // show the change now; send saves one at a time, replaying the change if the server copy moved on
  const base = data; fn(data); rerender(); busy++
  queue = queue.then(async () => {
    if (data !== base) fn(data)
    if (await api('PUT', { data, updateTime: rev }) === 409) { fn(data); await api('PUT', { data, updateTime: rev }) }
  }).catch(e => toast(`Not saved: ${e.message}`)).finally(() => busy--)
}
// ponytail: every request is a Vercel function call, so pull only when the tab comes back and every 5 minutes while
// it is in front; switch to Firestore listeners if Google sign-in is ever enabled.
let last = Date.now(); const maybePull = (min = 60000) => Date.now() - last > min && (last = Date.now(), pull())
setInterval(() => maybePull(300000), 60000); addEventListener('focus', () => maybePull()); document.addEventListener('visibilitychange', () => maybePull())
const signOut = () => { ls('token', null); user = data = null; rerender() }
let toastT; function toast(t) { const el = document.querySelector('.toast') || document.body.appendChild(Object.assign(document.createElement('div'), { className: 'toast' })); el.textContent = t; el.hidden = false; clearTimeout(toastT); toastT = setTimeout(() => el.hidden = true, 3000) }

// ---- Colors: same rules as the Mac app ----
const areaTint = a => a.hex || PAL[Math.abs(a.color ?? parseInt(a.id.slice(0, 2), 16)) % 8]
const goalTint = g => PAL[Math.abs(g.color || 0) % 8]
function tint(goalID, taskID) {
  const g = data.goals.find(x => x.id === goalID); if (g) return goalTint(g)
  const t = data.tasks.find(x => x.id === taskID), a = t && data.areas.find(x => x.id === t.areaID)
  return a ? areaTint(a) : '#A1A1AA'
}
const areas = () => data.areas.filter(a => !a.archived && !a.done)
const aicon = a => a ? a.icon || (a.isClass ? '◆' : '■') : '○'
let jump = null
const editArea = (id, f) => save(d => f(d.areas.find(a => a.id === id)))

// ---- AI: Claude through /api/ai, with the same context and memory the Mac app uses ----
const persona = `You are the Bearing coach: a direct but kind productivity coach. Name problems plainly, propose one specific change, and ask for approval. Principles: Goal, Plan, System: productivity means moving toward goals that matter, enjoyably and efficiently. Fewer goals, done better; help the person choose what to drop. Turn intentions into time on the calendar ("I will do X at time Y"). Protect deep work. Use the person's real data below; never invent facts about them. Keep replies short.`
const actionGuide = `You can act on the person's schedule. Only when they ask you to change, plan, reschedule, add or create something, end your reply with one block:
<actions>{"changes":[{"action":"add|move|remove","title":"...","goal":"exact goal title or null","blockId":"id for move/remove","day":"yyyy-MM-dd","start":"HH:mm","minutes":60}],"tasks":[{"title":"...","goal":"...","area":"class or project name or null"}]}</actions>
"tasks" are to-do items; "changes" are calendar blocks. Omit empty keys. Never overlap events. Keep the prose before it to one or two sentences; they will review and apply it.
Memory: when you learn something lasting about me (a preference, constraint, routine, recurring struggle, deadline, what works for me), add it on its own line as <remember>one short fact</remember>. Skip anything already in Memory. Most replies need none.`
function context() {
  const d = data, now = new Date(), k = C.dayKey()
  let o = `Today is ${now.toLocaleString([], { dateStyle: 'full', timeStyle: 'short' })}.\nCompass: ${d.compass || 'not set'}\n`
  o += 'Goals:\n' + C.goals(d).map(g => `- ${g.title} (${g.weeklyHours || 0} h/week, ${(C.focused(d, g.id, addDays(now, -7)) / 3600).toFixed(1)} h focused this week)${g.why ? ': ' + g.why : ''}`).join('\n') + '\n'
  if (areas().length) o += 'Classes and projects: ' + areas().map(a => a.name + (a.subs?.length ? ` (${a.subs.join(', ')})` : '')).join('; ') + '\n'
  const open = d.tasks.filter(t => !t.done).sort((a, b) => (a.due || '9') < (b.due || '9') ? -1 : 1).slice(0, 60)
  o += 'Open tasks:\n' + open.map(t => `- ${t.title}${t.due ? ' (due ' + C.dayKey(t.due) + ')' : ''}${C.areaName(d, t.areaID) ? ' [' + C.areaName(d, t.areaID) + ']' : ''}`).join('\n') + '\n'
  const bl = d.blocks.filter(b => new Date(b.start) >= addDays(now, -1) && new Date(b.start) <= addDays(now, 7)).sort((a, b) => a.start < b.start ? -1 : 1)
  o += 'Calendar blocks, next 7 days:\n' + bl.map(b => `- id ${b.id}: ${C.dayKey(b.start)} ${clock(b.start)}-${clock(b.end)} ${b.title}`).join('\n') + '\n'
  if (d.memory?.length) o += 'Memory (what you\'ve learned about me):\n' + d.memory.map(f => '- ' + f).join('\n') + '\n'
  const j = d.journal.filter(x => x.text && x.id <= k).sort((a, b) => a.id < b.id ? 1 : -1).slice(0, 3)
  if (j.length) o += 'Recent journal:\n' + j.map(x => `- ${x.id}: ${x.text.slice(0, 300)}`).join('\n') + '\n'
  return o
}
async function ai(messages, onTok, aiSessionId) {
  const r = await fetch('/api/ai', { method: 'POST', headers: auth(), body: JSON.stringify({ model: data.prefs.models?.bearing || 'anthropic/claude-sonnet-5.5', messages, stream: !!onTok, max_tokens: 2048, ...(aiSessionId && { aiSessionId }) }) })
  if (!r.ok) { const j = await r.json().catch(() => ({})); throw new Error(j.error?.message || j.error || `The coach is unavailable (${r.status}).`) }
  if (!onTok) return (await r.json()).choices?.[0]?.message?.content || ''
  const rd = r.body.getReader(), dec = new TextDecoder(); let buf = '', all = ''
  for (;;) {
    const { value, done } = await rd.read(); if (done) break
    buf += dec.decode(value, { stream: true }); const lines = buf.split('\n'); buf = lines.pop()
    for (const l of lines) { if (!l.startsWith('data: ') || l === 'data: [DONE]') continue
      try { const t = JSON.parse(l.slice(6)).choices?.[0]?.delta?.content; if (t) { all += t; onTok(t) } } catch {} }
  }
  return all
}
const json = s => { try { return JSON.parse(s.slice(s.indexOf('{'), s.lastIndexOf('}') + 1)) } catch { return null } }
function split(text) {
  const shown = text.replace(/<remember>[^<]*(<\/remember>)?/g, '').replace(/<actions>[\s\S]*?(<\/actions>|$)/, '').trim()
  const m = /<actions>([\s\S]*?)<\/actions>/.exec(text)
  return [shown, m ? json(m[1]) : null]
}
function learn(text) {
  const f = [...text.matchAll(/<remember>([^<]+)<\/remember>/g)].map(m => m[1].trim()).filter(Boolean)
  if (f.length) save(d => { const m = d.memory || []; for (const x of f) if (!m.some(y => y.toLowerCase() === x.toLowerCase())) m.push(x); d.memory = m.slice(-80) })
}
function perform(d, x) {
  const goalBy = t => C.goals(d).find(g => g.title === t)?.id
  for (const c of x.changes || []) {
    if (c.action === 'remove') { d.blocks = d.blocks.filter(b => b.id !== c.blockId?.toUpperCase()); continue }
    const [h, mi] = (c.start || '09:00').split(':').map(Number), s = C.parseDay(c.day || C.dayKey()); s.setHours(h, mi || 0)
    const b = c.action === 'move' && d.blocks.find(b => b.id === c.blockId?.toUpperCase())
    if (b) { const len = new Date(b.end) - new Date(b.start); b.start = C.iso(s); b.end = C.iso(+s + (c.minutes ? c.minutes * 60000 : len)) }
    else if (c.action !== 'move') { const t = d.tasks.find(t => !t.done && t.title === c.title); C.addBlock(d, { title: c.title, start: s, minutes: c.minutes || 60, goalID: goalBy(c.goal) || t?.goalID, taskID: t?.id }) }
  }
  for (const t of x.tasks || []) C.addTask(d, { title: t.title, goalID: goalBy(t.goal), areaID: d.areas.find(a => a.name.toLowerCase() === (t.area || '').toLowerCase())?.id })
}

// ---- Notifications while a tab is open ----
const sw = 'serviceWorker' in navigator ? navigator.serviceWorker.register('sw.js') : null
async function notify(title, body) {
  if (ls('notify') === false || globalThis.Notification?.permission !== 'granted') return
  const r = await sw?.catch(() => null); r ? r.showNotification(title, { body, icon: 'icon.png', tag: title }) : new Notification(title, { body, icon: 'icon.png' })
}
setInterval(() => {
  if (!data?.blocks) return
  const now = Date.now(), seen = ls('seen') || {}
  for (const b of data.blocks) { const s = +new Date(b.start); if (s > now - 60000 && s <= now + 60000 && !seen[b.id]) { seen[b.id] = 1; notify(`Starting: ${b.title}`, `${clock(b.start)} – ${clock(b.end)}`) } }
  const f = ls('focus'); if (f && !f.pausedAt && !f.told && now >= f.start + f.minutes * 60000 + f.paused * 1000) { f.told = 1; ls('focus', f); notify('Focus session done', f.title) }
  ls('seen', Object.fromEntries(Object.entries(seen).slice(-200)))
}, 20000)

// ---- Shell ----
function App() {
  const [, tick] = useState(0), [page, setPage] = useState(location.hash.slice(1) || 'Day')
  rerender = () => tick(n => n + 1)
  useEffect(() => { ls('token') ? api('GET').catch(e => { data = { error: e.message }; rerender() }) : (user = null, rerender()) }, [])
  useEffect(() => { const f = () => location.hash.startsWith('#t=') ? (ls('token', location.hash.slice(3)), location.replace('/')) : setPage(location.hash.slice(1) || 'Day'); addEventListener('hashchange', f); return () => removeEventListener('hashchange', f) }, [])
  if (user === undefined && ls('token')) return null
  if (!user) return html`<div class="login"><div><img src="icon.png" alt=""/><h1>Bearing</h1><p class="sub">Plan, focus and reflect with an AI coach. Synced with the Mac and iPhone apps.</p>
    <p class="sub" style="margin-top:16px">To sign in, open Bearing on your Mac and choose<br/><b>Settings › Agents › Open Bearing on the Web</b>.</p></div></div>`
  if (!data || data.error) return html`<div class="login"><div><h1>${data?.error ? 'Can\'t open your data' : 'Loading…'}</h1><p class="sub">${data?.error || ''}</p>${data?.error && html`<button onClick=${signOut}>Sign out</button>`}</div></div>`
  const P = { Day, Week, Month, Focus, Projects, Goals, Coach, Journal, Insights, Settings }[page] || Day
  const k = C.dayKey(), due = data.tasks.filter(t => !t.done && t.due && C.dayKey(t.due) <= k).length
  return html`<div class="top"><div class="logo"><img src="icon.png" alt=""/>Bearing</div>
    <nav class="modes">${MODES.map(([id, l]) => html`<a href=${'#' + id} class=${id === page ? 'on' : ''}>${l}</a>`)}</nav>
    <div class="right">${due > 0 && html`<span class="chip" style="--c:${PAL[1]}" title="Due today or overdue">${due} due</span>`}
      <a href="#Settings" class="avatar" title=${user.email}>${user.email.slice(0, 2).toUpperCase()}</a></div></div><${P}/>`
}

// ---- Day: tasks panel, Planned/Actual calendar, day panel ----
function Day() {
  const [day, setDay] = useState(() => { const j = jump || new Date(); jump = null; return j }), [plan, setPlan] = useState(null)
  return html`<div class="day"><${TasksPanel}/><${Calendar} day=${day} setDay=${setDay} onPlan=${() => setPlan({})}/><${DayPanel} day=${day} onPlan=${() => setPlan({})}/>
    ${plan && html`<${PlanModal} close=${() => setPlan(null)}/>`}</div>`
}
function TasksPanel() {
  const [done, setDone] = useState(false)
  const open = t => done || !t.done
  const list = [...areas().map(a => ({ a, c: areaTint(a), tasks: data.tasks.filter(t => t.areaID === a.id && open(t)) })),
    { a: null, c: '#A1A1AA', tasks: data.tasks.filter(t => open(t) && !areas().some(a => a.id === t.areaID)) }]
  return html`<div class="panel"><div class="ptitle"><span class="grow">All tasks</span><label class="small mute row" style="gap:6px"><input type="checkbox" class="switch" checked=${done} onChange=${() => setDone(!done)}/>Done</label></div>
    ${list.map(({ a, c, tasks }) => html`<div class="group" style="--c:${c}">
      <div class="ghead"><span class="gicon">${aicon(a)}</span>${a?.name || 'Unsorted'}</div>
      ${tasks.filter(t => !t.sub).map(t => html`<${TaskRow} t=${t} key=${t.id}/>`)}
      <${AddRow} areaID=${a?.id}/>
      ${(a?.subs || []).map(s => html`<div class="ghead" style="padding-left:24px;font-size:15px"><span class="gicon" style="width:28px;height:28px">▪</span>${s}</div>
        ${tasks.filter(t => t.sub === s).map(t => html`<${TaskRow} t=${t} sub key=${t.id}/>`)}<${AddRow} areaID=${a.id} sub=${s}/>`)}</div>`)}
    <div class="row small" style="margin-top:12px"><a class="mute" href="#Projects">Manage classes and projects</a></div></div>`
}
function TaskRow({ t, sub }) {
  const [edit, setEdit] = useState(false)
  return html`<div class=${'task' + (sub ? ' sub' : '') + (t.done ? ' done' : '')} draggable="true" onDragStart=${e => e.dataTransfer.setData('text/task', t.id)}>
    <button class=${'check' + (t.done ? ' on' : '')} aria-label="Complete" onClick=${() => save(d => C.setDone(d, C.task(d, t.id)))}>${t.done ? '✓' : ''}</button>
    <div class="t" onClick=${() => setEdit(true)} style="cursor:pointer">${t.title}
      ${(t.due || t.goalID) && html`<div class="meta">${[t.due && new Date(t.due).toLocaleDateString([], { month: 'short', day: 'numeric' }), C.goalTitle(data, t.goalID)].filter(Boolean).join(' · ')}</div>`}</div>
    ${edit && html`<${TaskEditor} t=${t} close=${() => setEdit(false)}/>`}</div>`
}
function TaskEditor({ t, close }) {
  const ch = (k, v) => save(d => C.updateTask(d, C.task(d, t.id), { [k]: v })), a = data.areas.find(x => x.id === t.areaID)
  const block = () => { const m = data.prefs.blockMinutes || 60, s = C.nextFree(data, m); if (!s) return toast('No free slot in the next two weeks'); save(d => C.addBlock(d, { title: t.title, start: s, minutes: m, goalID: t.goalID, taskID: t.id })); toast(`Blocked ${dayName(s)} ${clock(s)}`); close() }
  return html`<div class="modal" onClick=${e => e.target === e.currentTarget && close()}><div>
    <input class="plain" style="font-size:20px;font-weight:700" value=${t.title} onChange=${e => ch('title', e.target.value)}/>
    <div class="field"><span>Due</span><input type="date" value=${t.due ? C.dayKey(t.due) : ''} onChange=${e => ch('due', C.parseDay(e.target.value))}/></div>
    <div class="field"><span>Class or project</span><select value=${t.areaID || ''} onChange=${e => save(d => C.updateTask(d, C.task(d, t.id), { areaID: e.target.value || null, sub: null }))}><option value="">None</option>${areas().map(x => html`<option value=${x.id}>${x.name}</option>`)}</select></div>
    ${a?.subs?.length > 0 && html`<div class="field"><span>Sub-project</span><select value=${t.sub || ''} onChange=${e => ch('sub', e.target.value || null)}><option value="">None</option>${a.subs.map(s => html`<option>${s}</option>`)}</select></div>`}
    <div class="field"><span>Goal</span><select value=${t.goalID || ''} onChange=${e => ch('goalID', e.target.value || null)}><option value="">None</option>${C.goals(data).map(g => html`<option value=${g.id}>${g.title}</option>`)}</select></div>
    <div class="field"><span>Priority</span><select value=${t.priority} onChange=${e => ch('priority', +e.target.value)}>${[4, 3, 2, 1].map(p => html`<option value=${p}>${p === 1 ? 'Normal' : 'P' + (5 - p)}</option>`)}</select></div>
    <textarea style="margin-top:12px;min-height:80px" placeholder="Notes" onChange=${e => ch('notes', e.target.value)}>${t.notes}</textarea>
    ${t.resources?.map(r => html`<div><a href=${r} target="_blank" rel="noopener" class="small">${r}</a></div>`)}
    <div class="row" style="margin-top:18px"><button onClick=${block}>Block time</button><button class="ghost" onClick=${() => { if (confirm(`Delete "${t.title}"?`)) { save(d => C.deleteTask(d, C.task(d, t.id))); close() } }}>Delete</button><span class="grow"/><button class="primary" onClick=${close}>Done</button></div></div></div>`
}
function AddRow({ areaID, sub }) {
  const [v, setV] = useState('')
  return html`<form class=${'addrow' + (sub ? ' sub' : '')} style=${sub ? 'padding-left:72px' : ''} onSubmit=${e => { e.preventDefault(); if (v.trim()) save(d => C.addTask(d, { title: v.trim(), areaID, sub })); setV('') }}>
    <input placeholder="+ Add task…" value=${v} onInput=${e => setV(e.target.value)}/></form>`
}
const HPX = 64
function Calendar({ day, setDay, onPlan }) {
  const ref = useRef(), [, t] = useState(0), [over, setOver] = useState(false)
  useEffect(() => { const i = setInterval(() => t(n => n + 1), 60000); return () => clearInterval(i) }, [])
  const p = data.prefs, h0 = Math.max(0, (p.dayStart ?? 8) - 1), h1 = Math.min(24, (p.dayEnd ?? 20) + 2), base = new Date(day); base.setHours(h0, 0, 0, 0)
  const y = d => (new Date(d) - base) / 3600000 * HPX, isToday = sameDay(day, new Date())
  useEffect(() => { if (ref.current) ref.current.scrollTop = isToday ? Math.max(0, y(new Date()) - 160) : 0 }, [C.dayKey(day)])
  const blocks = data.blocks.filter(b => sameDay(b.start, day)), sess = data.sessions.filter(s => sameDay(s.start, day))
  const at = e => { const r = e.currentTarget.getBoundingClientRect(), m = Math.floor((e.clientY - r.top) / HPX * 4) / 4; const s = new Date(base); s.setMinutes(m * 60); return s }
  const add = e => { const s = at(e), title = prompt(`New block at ${clock(s)}`); if (title) save(d => C.addBlock(d, { title, start: s, minutes: p.blockMinutes || 60 })) }
  const drop = e => { e.preventDefault(); setOver(false); const id = e.dataTransfer.getData('text/task'), tk = data.tasks.find(x => x.id === id); if (tk) { const s = at(e); save(d => C.addBlock(d, { title: tk.title, start: s, minutes: p.blockMinutes || 60, goalID: tk.goalID, taskID: tk.id })) } }
  const editBlock = (e, b) => { e.stopPropagation(); const v = prompt('Rename the block, or clear the name to delete it', b.title); if (v === null) return; save(d => { if (!v.trim()) d.blocks = d.blocks.filter(x => x.id !== b.id); else d.blocks.find(x => x.id === b.id).title = v.trim() }) }
  return html`<div class="panel cal"><div class="calhead"><button class="ghost" onClick=${() => setDay(addDays(day, -1))} aria-label="Previous day">‹</button>
    <button class="ghost" onClick=${() => setDay(addDays(day, 1))} aria-label="Next day">›</button><button disabled=${isToday} onClick=${() => setDay(new Date())}>Today</button>
    <div class="grow" style="text-align:center;font-weight:700;font-size:18px">${day.toLocaleDateString([], { weekday: 'short' })}<span class="dnum" style=${isToday ? '' : 'background:var(--hover);color:var(--ink)'}>${day.getDate()}</span></div>
    <button class="primary" onClick=${onPlan}>Plan with Coach</button></div>
    <div class="cols"><span/><span>Planned</span><span>Actual</span></div>
    <div class="grid" ref=${ref}><div class="hours" style=${`height:${(h1 - h0) * HPX}px`}>
      ${[...Array(h1 - h0)].map((_, i) => html`<div class="hl" style=${`top:${i * HPX}px`}/><span class="hlab" style=${`top:${i * HPX}px`}>${String(h0 + i).padStart(2, '0')}:00</span>`)}
      <div class=${'lane plan' + (over ? ' over' : '')} style="height:100%" onClick=${add} onDragOver=${e => { e.preventDefault(); setOver(true) }} onDragLeave=${() => setOver(false)} onDrop=${drop}>
        ${blocks.map(b => html`<div class=${'blk' + (b.done ? ' done' : '')} style=${`--c:${tint(b.goalID, b.taskID)};top:${y(b.start)}px;height:${Math.max(24, y(b.end) - y(b.start) - 2)}px`} onClick=${e => editBlock(e, b)}><b>${b.title}</b>${clock(b.start)} – ${clock(b.end)}</div>`)}</div>
      <div class="lane act" style="height:100%">${sess.map(s => { const e = +new Date(s.start) + (s.seconds + s.pausedSeconds) * 1000
        return html`<div class="blk" style=${`--c:${tint(s.goalID, s.taskID)};top:${y(s.start)}px;height:${Math.max(24, y(e) - y(s.start) - 2)}px`}><b>${s.title || 'Focus'} <span style="float:right">${C.quality(s)}%</span></b>${clock(s.start)} – ${clock(e)}</div>` })}</div>
      ${isToday && html`<div class="now" style=${`top:${y(new Date())}px`}><span>${clock(new Date())}</span></div>`}</div></div></div>`
}
function DayPanel({ day, onPlan }) {
  const k = C.dayKey(day), focused = data.sessions.filter(s => sameDay(s.start, day)).reduce((a, s) => a + s.seconds, 0)
  const planned = data.blocks.filter(b => sameDay(b.start, day)).reduce((a, b) => a + (new Date(b.end) - new Date(b.start)) / 1000, 0)
  const due = data.tasks.filter(t => !t.done && t.due && C.dayKey(t.due) <= k), pct = planned ? Math.min(100, Math.round(focused / planned * 100)) : 0
  const j = data.journal.find(x => x.id === k), steps = [['Plan', planned > 0, onPlan], ['Focus', focused > 0, () => location.hash = 'Focus'], ['Reflect', !!j?.text, () => location.hash = 'Journal']]
  return html`<div class="panel"><div class="big">${pct}%</div><div class="bar"><i style=${`width:${pct}%`}/></div>
    <p class="sub small">${dur(focused)} focused / ${dur(planned)} planned · ${due.length} due</p>
    <div class="pills">${steps.map(([l, on, f]) => html`<button class="pill" onClick=${f}><span class=${'dot' + (on ? ' on' : '')}>${on ? '✓' : ''}</span>${l}</button>`)}</div>
    ${due.length > 0 && html`<div class="sect"><h3>Due</h3>${due.map(t => html`<div class="row small" style="padding:4px 0"><button class="check" style=${`--c:${tint(t.goalID, t.id)}`} onClick=${() => save(d => C.setDone(d, C.task(d, t.id)))}/>${t.title}</div>`)}</div>`}
    <div class="sect"><h3>Sessions</h3>${data.sessions.filter(s => sameDay(s.start, day)).map(s => html`<div class="row" style="padding:4px 0"><span class="sw" style=${`--c:${tint(s.goalID, s.taskID)};width:8px;height:8px`}/><div class="grow">${s.title || 'Focus'}<div class="small mute">${clock(s.start)} · ${dur(s.seconds)}</div></div><b>${C.quality(s)}%</b></div>`)}
      ${!data.sessions.some(s => sameDay(s.start, day)) && html`<p class="sub small">No focus sessions yet.</p>`}</div>
    <div class="sect"><h3>Notes</h3><textarea key=${k} placeholder="How did the day go?" onChange=${e => save(d => C.writeJournal(d, k, e.target.value, true))}>${j?.text || ''}</textarea></div></div>`
}
function PlanModal({ close }) {
  const [st, setSt] = useState({ busy: true })
  useEffect(() => {
    const p = `It's ${clock(new Date())}. Plan my day for today only, from now until evening; nothing before now. Anything due today or tomorrow comes first. Reply with JSON only: {"summary":"one sentence","changes":[{"action":"add|move|remove","title":"...","goal":"exact goal title or null","blockId":"block id for move or remove","day":"${C.dayKey()}","start":"HH:mm","minutes":60,"reason":"short"}]}. Put core goals first and in my best hours. Never overlap existing blocks. 3 to 5 blocks is plenty. Use open tasks as block titles where they fit.`
    ai([{ role: 'system', content: persona + '\n\n' + context() }, { role: 'user', content: p }]).then(r => setSt({ plan: json(r) || { summary: r, changes: [] } })).catch(e => setSt({ error: e.message }))
  }, [])
  return html`<div class="modal" onClick=${e => e.target === e.currentTarget && close()}><div><h1 style="font-size:24px">Plan with Coach</h1>
    ${st.busy && html`<p class="sub">Your coach is planning the rest of today…</p>`}${st.error && html`<p class="sub">${st.error}</p>`}
    ${st.plan && html`<p>${st.plan.summary}</p>${st.plan.changes.map(c => html`<div class="row" style="padding:8px 0;border-bottom:1px solid var(--line)"><b style="width:64px">${c.start || ''}</b><div class="grow">${c.action === 'add' ? '' : c.action + ': '}${c.title}<div class="small mute">${c.reason || ''}</div></div><span class="small mute">${c.minutes ? c.minutes + 'm' : ''}</span></div>`)}`}
    <div class="row" style="margin-top:18px"><span class="grow"/><button onClick=${close}>Cancel</button>${st.plan?.changes.length > 0 && html`<button class="primary" onClick=${() => { save(d => perform(d, st.plan)); toast('Plan applied'); close() }}>Apply</button>`}</div></div></div>`
}

// ---- Week ----
function Week() {
  const [start, setStart] = useState(() => { const d = new Date(); d.setDate(d.getDate() - ((d.getDay() + 6) % 7)); return d })
  const days = [...Array(7)].map((_, i) => addDays(start, i))
  return html`<div class="page" style="max-width:1400px"><div class="row" style="margin-bottom:18px"><h1 class="grow">Week of ${start.toLocaleDateString([], { month: 'long', day: 'numeric' })}</h1>
    <button class="ghost" onClick=${() => setStart(addDays(start, -7))}>‹</button><button onClick=${() => setStart(addDays(new Date(), -((new Date().getDay() + 6) % 7)))}>This week</button><button class="ghost" onClick=${() => setStart(addDays(start, 7))}>›</button></div>
    <div class="week">${days.map(d => html`<div class=${'col' + (sameDay(d, new Date()) ? ' today' : '')}><div style="font-weight:700;margin-bottom:10px">${d.toLocaleDateString([], { weekday: 'short', day: 'numeric' })}</div>
      ${data.blocks.filter(b => sameDay(b.start, d)).sort((a, b) => a.start < b.start ? -1 : 1).map(b => html`<div class="blk" style=${`--c:${tint(b.goalID, b.taskID)}`}><b>${b.title}</b>${clock(b.start)}</div>`)}
      ${data.tasks.filter(t => !t.done && t.due && sameDay(t.due, d)).map(t => html`<div class="small" style="padding:4px 0">○ ${t.title}</div>`)}</div>`)}</div></div>`
}

// ---- Projects: Priority · Active · Done, compact rows ----
const EMOJI = '📚 📐 🧪 🔬 🧬 💻 🖥️ 🤖 🧠 📊 📈 💹 💰 🏦 📝 ✍️ 📖 🔤 🗣️ 🌍 🎨 🎬 🎥 📷 🎵 🎸 🎹 ♟️ ⚽ 🏀 🏏 🎾 🏓 🛹 🏃 🧘 💪 🍳 🌱 🛠️ 🔧 ⚙️ 🚀 ✈️ 🏠 🛒 📦 🏷️ 💼 📣 💡 🔥 ⭐ 🎯 🏆 ❤️ 🙏 🕉️ 🧩 🎮 📱 🌐 🔒 📅 ✅'.split(' ')
function Projects() {
  const [arch, setArch] = useState(false), [nw, setNw] = useState(''), [open, setOpen] = useState(null), [style, setStyle] = useState(null)
  const add = isClass => save(d => d.areas.push({ id: C.uuid(), name: isClass ? 'New class' : 'New project', isClass, color: d.areas.length % 8 }))
  const rename = (a, v) => v.trim() && v.trim() !== a.name && save(d => { const x = d.areas.find(y => y.id === a.id); x.name = v.trim(); C.relabel(d, x) })
  const kind = (a, c) => save(d => { const x = d.areas.find(y => y.id === a.id); x.isClass = c; C.relabel(d, x) })
  const del = a => confirm(`Delete ${a.name}? Its tasks stay, unsorted.`) && save(d => { d.areas = d.areas.filter(x => x.id !== a.id); for (const t of d.tasks) if (t.areaID === a.id) { delete t.areaID; delete t.sub; C.updateTask(d, t, { areaID: null }) } })
  const set = (a, k) => editArea(a.id, x => { for (const f of ['priority', 'done', 'archived']) delete x[f]; if (k) x[k] = true })
  const S = [['Priority', a => a.priority && !a.done && !a.archived], ['Active', a => !a.priority && !a.done && !a.archived], ['Done', a => a.done && !a.archived], ...(arch ? [['Archived', a => a.archived]] : [])]
  const row = a => { const c = areaTint(a), ts = data.tasks.filter(t => t.areaID === a.id), n = ts.filter(t => !t.done).length
    return html`<div class="prow" style=${`--c:${c}`} key=${a.id}><div class="row">
      <button class="gicon" title="Icon and color" onClick=${() => setStyle(a.id)}>${aicon(a)}</button>
      <input class="plain grow" style="font-weight:600" value=${a.name} onChange=${e => rename(a, e.target.value)} onKeyDown=${e => e.key === 'Enter' && e.target.blur()}/>
      <span class="small mute nowrap">${n} open</span>
      <div class="seg small"><button class=${a.isClass ? 'on' : ''} onClick=${() => kind(a, true)}>Class</button><button class=${a.isClass ? '' : 'on'} onClick=${() => kind(a, false)}>Project</button></div>
      <select class="small" style="width:170px" value=${a.goal || ''} onChange=${e => editArea(a.id, x => e.target.value ? x.goal = e.target.value : delete x.goal)}><option value="">No goal</option>${C.goals(data).map(g => html`<option value=${g.id}>${g.title}</option>`)}</select>
      <button class="ghost" title="Sub-projects" aria-expanded=${open === a.id} onClick=${() => setOpen(open === a.id ? null : a.id)}>${open === a.id ? '▾' : '▸'} ${(a.subs || []).length || ''}</button>
      <select class="ghost menu" aria-label="More" value="" onChange=${e => { const v = e.target.value; e.target.value = ''; v === 'del' ? del(a) : set(a, v === 'active' ? null : v) }}>
        <option value="">⋯</option>${!a.priority && html`<option value="priority">Mark priority</option>`}${(a.priority || a.done || a.archived) && html`<option value="active">Make active</option>`}
        ${!a.done && html`<option value="done">Mark done</option>`}${!a.archived && html`<option value="archived">Archive</option>`}<option value="del">Delete…</option></select></div>
      ${open === a.id && html`<div class="row wrap" style="gap:8px;padding:10px 0 4px 46px">${(a.subs || []).map(s => html`<span class="chip">${s} <span style="opacity:.6">${ts.filter(t => t.sub === s && !t.done).length}</span><button aria-label="Remove" onClick=${() => save(d => { const x = d.areas.find(y => y.id === a.id); x.subs = x.subs.filter(y => y !== s); for (const t of d.tasks) if (t.areaID === a.id && t.sub === s) C.updateTask(d, t, { sub: null }) })}>✕</button></span>`)}
        <form onSubmit=${e => { e.preventDefault(); const s = nw.trim(); if (s && !(a.subs || []).includes(s)) editArea(a.id, x => x.subs = [...(x.subs || []), s]); setNw('') }}><input class="plain small" style="width:160px" placeholder="+ Add sub-project" value=${nw} onInput=${e => setNw(e.target.value)}/></form></div>`}</div>` }
  const sa = style && data.areas.find(a => a.id === style)
  return html`<div class="page"><div class="row wrap" style="margin-bottom:22px"><div class="grow"><h1>Classes and projects</h1><p class="sub">Group tasks, give each an icon and color, and link it to a goal.</p></div>
      <label class="row small mute" style="gap:6px"><input type="checkbox" class="switch" checked=${arch} onChange=${() => setArch(!arch)}/>Archived</label>
      <button onClick=${() => add(true)}>New class</button><button class="primary" onClick=${() => add(false)}>New project</button></div>
    ${S.map(([l, f]) => { const xs = data.areas.filter(f); return xs.length > 0 && html`<h2>${l}</h2><div class="card list">${xs.map(row)}</div>` })}
    ${!data.areas.length && html`<div class="card mute">No classes or projects yet.</div>`}
    ${sa && html`<div class="modal" onClick=${e => e.target === e.currentTarget && setStyle(null)}><div><div class="row"><h1 class="grow" style="font-size:22px">${sa.name}</h1><button onClick=${() => setStyle(null)}>Done</button></div>
      <h2>Color</h2><div class="row wrap" style="gap:8px">${PAL.map((p, i) => html`<button class=${'sw' + (!sa.hex && (sa.color ?? parseInt(sa.id.slice(0, 2), 16)) % 8 === i ? ' on' : '')} style=${`--c:${p}`} title=${PALN[i]} onClick=${() => editArea(sa.id, x => { x.color = i; delete x.hex })}/>`)}
        <input type="color" value=${areaTint(sa)} onInput=${e => editArea(sa.id, x => x.hex = e.target.value.toUpperCase())} style="width:44px;height:30px;padding:2px"/>
        <input style="width:110px" value=${sa.hex || ''} placeholder="#3FAE86" onChange=${e => /^#?[0-9a-f]{6}$/i.test(e.target.value.trim()) && editArea(sa.id, x => x.hex = ('#' + e.target.value.trim().replace('#', '')).toUpperCase())}/></div>
      <h2>Icon</h2><div class="emoji"><button onClick=${() => editArea(sa.id, x => delete x.icon)}>None</button>${EMOJI.map(e => html`<button class=${sa.icon === e ? 'on' : ''} onClick=${() => editArea(sa.id, x => x.icon = e)}>${e}</button>`)}</div>
      <input style="margin-top:12px" placeholder="Or type any emoji" maxlength="4" onChange=${e => e.target.value.trim() && editArea(sa.id, x => x.icon = e.target.value.trim())}/></div></div>`}</div>`
}

// ---- Month ----
function Month() {
  const [m, setM] = useState(() => { const d = new Date(); d.setDate(1); return d })
  const first = addDays(m, -((m.getDay() + 6) % 7)), days = [...Array(42)].map((_, i) => addDays(first, i))
  const go = d => { jump = d; location.hash = 'Day' }
  return html`<div class="page" style="max-width:1400px"><div class="row wrap" style="margin-bottom:18px"><h1 class="grow">${m.toLocaleDateString([], { month: 'long', year: 'numeric' })}</h1>
    <button class="ghost" aria-label="Previous month" onClick=${() => setM(new Date(m.getFullYear(), m.getMonth() - 1, 1))}>‹</button><button onClick=${() => { const d = new Date(); d.setDate(1); setM(d) }}>This month</button><button class="ghost" aria-label="Next month" onClick=${() => setM(new Date(m.getFullYear(), m.getMonth() + 1, 1))}>›</button></div>
    <div class="month">${['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'].map(d => html`<div class="small mute" style="padding:0 8px">${d}</div>`)}
      ${days.map(d => { const bs = data.blocks.filter(b => sameDay(b.start, d)).sort((a, b) => a.start < b.start ? -1 : 1), ts = data.tasks.filter(t => !t.done && t.due && sameDay(t.due, d)), all = [...bs, ...ts]
        return html`<button class=${'mday' + (d.getMonth() !== m.getMonth() ? ' out' : '') + (sameDay(d, new Date()) ? ' today' : '')} onClick=${() => go(d)}><span class="mnum">${d.getDate()}</span>
          ${all.slice(0, 3).map(x => html`<div class="mitem" style=${`--c:${x.start ? tint(x.goalID, x.taskID) : tint(x.goalID, x.id)}`}>${x.start ? '' : '○ '}${x.title}</div>`)}${all.length > 3 && html`<div class="small mute">+${all.length - 3} more</div>`}</button>` })}</div></div>`
}

// ---- Goals ----
function Goals() {
  const wk = addDays(new Date(), -7), up = (g, k, v) => save(d => { d.goals.find(x => x.id === g.id)[k] = v })
  return html`<div class="page"><h1>Goals</h1><p class="sub">${data.seasonName || ''}${data.seasonWeeks ? ` · ${data.seasonWeeks} weeks` : ''}</p><div style="height:22px"/>
    ${C.goals(data).map(g => { const h = C.focused(data, g.id, wk) / 3600, c = goalTint(g)
      return html`<div class="card accent" style=${`--c:${c}`}><div class="row"><b class="grow" style="font-size:18px">${g.title}</b>
        <select style="width:150px" value=${g.status} onChange=${e => up(g, 'status', e.target.value)}>${[['none', 'Not reviewed'], ['onTrack', 'On track'], ['adjust', 'Adjust'], ['offTrack', 'Off track']].map(([v, l]) => html`<option value=${v}>${l}</option>`)}</select></div>
        ${g.why && html`<p class="sub" style="margin-top:8px">${g.why}</p>`}<div class="bar"><i style=${`width:${Math.min(100, h / (g.weeklyHours || 1) * 100)}%`}/></div>
        <p class="small mute">${h.toFixed(1)} of ${g.weeklyHours || 0} h this week · ${data.tasks.filter(t => t.goalID === g.id && !t.done).length} open tasks${g.metric ? ' · Done when: ' + g.metric : ''}</p>
        <textarea style="min-height:60px;margin-top:10px" placeholder="Next actions" onChange=${e => up(g, 'notes', e.target.value)}>${g.notes || ''}</textarea></div>` })}</div>`
}

// ---- Focus ----
function Focus() {
  const [f, setF] = useState(ls('focus')), [, t] = useState(0), set = v => { ls('focus', v); setF(v) }
  useEffect(() => { const i = setInterval(() => t(n => n + 1), 1000); return () => clearInterval(i) }, [])
  const [goal, setGoal] = useState(''), [title, setTitle] = useState(''), [min, setMin] = useState(data.prefs.workMinutes || 25), [busy, setBusy] = useState(false)
  const c = f ? tint(f.goalID) : goal ? tint(goal) : 'var(--brand)'
  const suggest = async () => { setBusy(true); try { const r = json(await ai([{ role: 'system', content: persona + '\n\n' + context() }, { role: 'user', content: `It's ${clock(new Date())}. What one thing should I focus on right now? Weigh deadlines, my current block, and my core goals. Reply with JSON only: {"title":"verb first, under 8 words","goal":"exact goal title or null"}` }])); if (r) { setTitle(r.title); setGoal(C.goals(data).find(g => g.title === r.goal)?.id || goal) } } catch (e) { toast(e.message) } setBusy(false) }
  const ring = (frac, label) => html`<div class="ring"><svg viewBox="0 0 100 100"><circle cx="50" cy="50" r="46" fill="none" stroke=${`color-mix(in srgb, ${c} 16%, transparent)`} stroke-width="4"/>
    <circle cx="50" cy="50" r="46" fill="none" stroke=${c} stroke-width="4" stroke-linecap="round" stroke-dasharray="289" stroke-dashoffset=${289 * (1 - frac)} style="transition:stroke-dashoffset 1s linear"/></svg><div class="timer">${label}</div></div>`
  if (!f) return html`<div class="page" style="max-width:640px"><div class="card" style="text-align:center;padding:36px">
    <div class="row"><input placeholder="What are you focusing on?" value=${title} onInput=${e => setTitle(e.target.value)}/><button disabled=${busy} onClick=${suggest}>${busy ? 'Thinking…' : 'Suggest'}</button></div>
    <div class="row" style="margin-top:10px"><select value=${goal} onChange=${e => setGoal(e.target.value)}><option value="">No goal</option>${C.goals(data).map(g => html`<option value=${g.id}>${g.title}</option>`)}</select>
      <select style="width:140px" value=${min} onChange=${e => setMin(+e.target.value)}>${[15, 25, 45, 60, 90].map(m => html`<option value=${m}>${m} minutes</option>`)}</select></div>
    ${ring(0, `${String(min).padStart(2, '0')}:00`)}
    <button class="primary" style="padding:12px 32px;font-size:16px" onClick=${() => { globalThis.Notification?.permission === 'default' && Notification.requestPermission(); set({ start: Date.now(), minutes: min, goalID: goal, title: title || C.goalTitle(data, goal) || 'Focus', paused: 0, pausedAt: null, distractions: 0 }) }}>Start focus</button></div></div>`
  const now = f.pausedAt || Date.now(), el = (now - f.start) / 1000 - f.paused, left = Math.max(0, f.minutes * 60 - el)
  const stop = () => { if (el > 60) save(d => d.sessions.push({ id: C.uuid(), title: f.title, ...(f.goalID && { goalID: f.goalID }), start: C.iso(f.start), seconds: Math.round(Math.min(el, f.minutes * 60)), pausedSeconds: Math.round(f.paused), distractions: f.distractions })); set(null) }
  return html`<div class="page" style="max-width:640px"><div class="card" style="text-align:center;padding:36px"><h1>${f.title}</h1>
    ${ring(1 - left / (f.minutes * 60), `${Math.floor(left / 60)}:${String(Math.floor(left % 60)).padStart(2, '0')}`)}
    <div class="row" style="justify-content:center">${f.pausedAt ? html`<button onClick=${() => set({ ...f, paused: f.paused + (Date.now() - f.pausedAt) / 1000, pausedAt: null })}>Resume</button>` : html`<button onClick=${() => set({ ...f, pausedAt: Date.now() })}>Pause</button>`}
    <button onClick=${() => set({ ...f, distractions: f.distractions + 1 })}>Distracted · ${f.distractions}</button><button class="primary" onClick=${stop}>${left ? 'End' : 'Save'} session</button></div></div></div>`
}

// ---- Coach: chat on Claude, with memory ----
function Coach() {
  const [v, setV] = useState(''), [busy, setBusy] = useState(false), [mem, setMem] = useState(false), end = useRef()
  useEffect(() => end.current?.scrollIntoView({ block: 'end' }))
  const send = async () => {
    const text = v.trim(); if (!text || busy) return; setV(''); setBusy(true)
    const reply = { id: C.uuid(), role: 'assistant', text: '' }
    data.chat ||= []; data.chat.push({ id: C.uuid(), role: 'user', text }, reply); rerender()
    try {
      const msgs = [{ role: 'system', content: persona + '\n\n' + actionGuide + '\n\n' + context() }, ...data.chat.slice(-13, -1).map(m => ({ role: m.role, content: split(m.text)[0] || m.text }))]
      await ai(msgs, tok => { reply.text += tok; rerender() }, data.chat[0]?.id)
      learn(reply.text)
    } catch (e) { reply.text = e.message }
    save(() => {}); setBusy(false)
  }
  const apply = (m, x) => save(d => { perform(d, x); const y = d.chat.find(c => c.id === m.id); if (y) y.applied = true })
  return html`<div class="page" style="max-width:760px"><div class="row"><h1 class="grow">Coach</h1><button onClick=${() => setMem(true)}>Memory · ${data.memory?.length || 0}</button>
    <button class="ghost" onClick=${() => confirm('Start a new chat?') && save(d => { d.chat = [] })}>New chat</button></div>
    <p class="sub">Runs on Claude. It knows your goals, tasks, calendar and what it has learned about you.</p>
    <div class="chat">${(data.chat || []).map(m => { const [shown, x] = split(m.text)
      return html`<div class=${'msg ' + m.role}>${shown || (busy ? '…' : '')}${x && html`<div class="actions">${(x.changes || []).map(c => html`<div>${c.action} block: ${c.title || ''} ${c.day || ''} ${c.start || ''}</div>`)}${(x.tasks || []).map(t => html`<div>add task: ${t.title}</div>`)}
        <button class="primary" style="margin-top:8px" disabled=${m.applied} onClick=${() => apply(m, x)}>${m.applied ? 'Applied' : 'Apply'}</button></div>`}</div>` })}<div ref=${end}/></div>
    <form class="row" onSubmit=${e => { e.preventDefault(); send() }}><input placeholder="Ask your coach, or tell it what to plan" value=${v} onInput=${e => setV(e.target.value)}/><button class="primary" disabled=${busy}>${busy ? '…' : 'Send'}</button></form>
    ${mem && html`<div class="modal" onClick=${e => e.target === e.currentTarget && setMem(false)}><div><h1 style="font-size:22px">What the coach remembers</h1><p class="sub small">It learns these from your chats and reflections and uses them in every plan and reply.</p>
      ${(data.memory || []).slice().reverse().map(f => html`<div class="row" style="padding:8px 0;border-bottom:1px solid var(--line)"><span class="grow">${f}</span><button class="ghost" title="Forget" onClick=${() => save(d => { d.memory = d.memory.filter(x => x !== f) })}>✕</button></div>`)}
      ${!data.memory?.length && html`<p class="sub">Nothing yet.</p>`}<div class="row" style="margin-top:16px"><span class="grow"/><button class="primary" onClick=${() => setMem(false)}>Done</button></div></div></div>`}</div>`
}

// ---- Journal, Insights, Settings ----
function Journal() {
  const [k, setK] = useState(C.dayKey()), e = data.journal.find(j => j.id === k)
  return html`<div class="page"><div class="row"><h1 class="grow">Journal</h1><input type="date" style="width:auto" value=${k} onChange=${x => setK(x.target.value || C.dayKey())}/></div>
    ${e?.prompt && html`<p class="sub">${e.prompt}</p>`}<div class="card" style="margin-top:18px"><textarea key=${k} style="min-height:220px;background:none" placeholder="How did today go? What drained you, what worked?" onChange=${x => save(d => C.writeJournal(d, k, x.target.value, true))}>${e?.text || ''}</textarea></div>
    <h2>Recent</h2>${data.journal.filter(j => j.text).sort((a, b) => a.id < b.id ? 1 : -1).slice(0, 10).map(j => html`<div class="card" style="cursor:pointer" onClick=${() => setK(j.id)}><b>${dayName(C.parseDay(j.id))}</b><p class="sub small" style="margin-top:4px">${j.text.slice(0, 200)}</p></div>`)}</div>`
}
function Insights() {
  const [span, setSpan] = useState(7), since = addDays(new Date(), -span), k = C.dayKey()
  const ss = data.sessions.filter(s => new Date(s.start) >= since), dn = data.tasks.filter(t => t.done && t.doneAt && new Date(t.doneAt) >= since)
  const days = [...Array(Math.min(span, 31))].map((_, i) => addDays(new Date(), i - Math.min(span, 31) + 1)), fx = d => ss.filter(s => sameDay(s.start, d)).reduce((a, s) => a + s.seconds, 0)
  const mx = Math.max(1, ...days.map(fx)), sec = id => ss.filter(s => data.tasks.find(t => t.id === s.taskID)?.areaID === id).reduce((a, s) => a + s.seconds, 0)
  return html`<div class="page"><div class="row wrap"><div class="grow"><h1>Stats</h1><p class="sub">Focus, tasks, classes and goals.</p></div>
    <div class="seg">${[[7, 'Week'], [30, 'Month'], [90, 'Season']].map(([n, l]) => html`<button class=${span === n ? 'on' : ''} onClick=${() => setSpan(n)}>${l}</button>`)}</div></div>
    <div class="stats" style="margin-top:22px">${[['Focused', dur(ss.reduce((a, s) => a + s.seconds, 0))], ['Tasks done', dn.length], ['Overdue', data.tasks.filter(t => !t.done && t.due && C.dayKey(t.due) < k).length], ['Focus days', new Set(ss.map(s => C.dayKey(s.start))).size]].map(([l, v]) => html`<div class="card stat"><div class="small mute">${l}</div><div class="v">${v}</div></div>`)}</div>
    <h2>Each day</h2><div class="card"><div class="chart">${days.map(d => html`<div title=${`${dayName(d)}: ${dur(fx(d))}, ${dn.filter(t => sameDay(t.doneAt, d)).length} tasks`}><i style=${`height:${fx(d) / mx * 100}%`}/>${span <= 7 && html`<span class="small mute">${d.toLocaleDateString([], { weekday: 'narrow' })}</span>`}</div>`)}</div></div>
    <h2>Classes and projects</h2><div class="card list">${areas().map(a => { const ts = data.tasks.filter(t => t.areaID === a.id)
      return html`<div class="prow row" style=${`--c:${areaTint(a)}`}><span class="gicon">${aicon(a)}</span><span class="grow">${a.name}</span><span class="small mute">${dn.filter(t => t.areaID === a.id).length} done · ${ts.filter(t => !t.done).length} open · ${dur(sec(a.id))}</span></div>` })}</div>
    <h2>Goals</h2><div class="card">${C.goals(data).map(g => { const h = C.focused(data, g.id, since) / 3600, tgt = (g.weeklyHours || 0) * span / 7; return html`<div style=${`--c:${goalTint(g)};padding:6px 0`}><div class="row"><span class="grow">${g.title}</span><span class="small mute">${h.toFixed(1)} / ${tgt.toFixed(0)} h</span></div><div class="bar" style="margin:8px 0"><i style=${`width:${Math.min(100, h / (tgt || 1) * 100)}%`}/></div></div>` })}</div></div>`
}
function Settings() {
  const p = data.prefs, set = (k, v) => save(d => { d.prefs[k] = v }), [n, setN] = useState(ls('notify') !== false && globalThis.Notification?.permission === 'granted')
  const token = p.agentKey && `bk_${btoa(user.email).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')}_${p.agentKey}`, url = location.origin + '/api/mcp'
  const key = () => [...crypto.getRandomValues(new Uint8Array(32))].map(b => b.toString(16).padStart(2, '0')).join('')
  const copy = t => navigator.clipboard.writeText(t).then(() => toast('Copied'))
  const num = (k, l, def, min, max, step = 1) => html`<div class="field"><span>${l}</span><input type="number" min=${min} max=${max} step=${step} value=${p[k] ?? def} onChange=${e => set(k, +e.target.value)}/></div>`
  return html`<div class="page"><h1>Settings</h1><p class="sub">Voice capture, site blocking, local models, Calendar and Todoist sync run in the Mac and iPhone apps.</p>
    <h2>Coach</h2><div class="card"><div class="field"><span>Model</span><select value=${p.models?.bearing || 'anthropic/claude-sonnet-5.5'} onChange=${e => set('models', { ...(p.models || {}), bearing: e.target.value })}>
      ${[['anthropic/claude-sonnet-5.5', 'Sonnet 5.5 (balanced)'], ['anthropic/claude-haiku-5.5', 'Haiku 5.5 (fastest)'], ['anthropic/claude-opus-5.5', 'Opus 5.5 (deepest)']].map(([v, l]) => html`<option value=${v}>${l}</option>`)}</select></div></div>
    <h2>Notifications</h2><div class="card"><div class="field"><span>Remind me when blocks start and focus ends (while a Bearing tab is open)</span>
      <input type="checkbox" checked=${n} onChange=${async () => { if (n) { ls('notify', false); setN(false) } else { const r = await Notification.requestPermission(); ls('notify', r === 'granted'); setN(r === 'granted'); r !== 'granted' && toast('Allow notifications for this site in your browser') } }}/></div></div>
    <h2>Planning</h2><div class="card">${num('blockMinutes', 'Time block length (minutes)', 60, 15, 240, 15)}${num('dayStart', 'Day starts at (hour)', 9, 0, 23)}${num('dayEnd', 'Day ends at (hour)', 19, 1, 24)}
      <div class="field"><span>Tag Todoist tasks with class and project</span><input type="checkbox" checked=${p.labelSync !== false} onChange=${e => set('labelSync', e.target.checked)}/></div></div>
    <h2>Agent permissions</h2><div class="card">${C.SCOPES.map(s => html`<div class="field"><span>${s.title}<div class="small mute">${s.detail}</div></span>
      <select value=${C.mode(data, s.key)} onChange=${e => set('agentAccess', { ...(p.agentAccess || {}), [s.key]: e.target.value })}>${[['off', 'Off'], ['ask', 'Ask each time'], ['allow', 'Allow']].map(([v, l]) => html`<option value=${v}>${l}</option>`)}</select></div>`)}</div>
    <h2>Remote MCP server</h2><div class="card">${token ? html`<p class="small mute">Any agent, server or device can connect. "Ask each time" counts as Off here, since nobody is there to ask.</p>
      <p><code>claude mcp add --transport http bearing ${url} --header "Authorization: Bearer ${token}"</code></p>
      <div class="row wrap"><button onClick=${() => copy(`claude mcp add --transport http bearing ${url} --header "Authorization: Bearer ${token}"`)}>Copy command</button>
      <button onClick=${() => copy(token)}>Copy token</button><button onClick=${() => confirm('Disconnect every remote agent?') && set('agentKey', key())}>New token</button><button class="ghost" onClick=${() => set('agentKey', null)}>Turn off</button></div>`
      : html`<button class="primary" onClick=${() => set('agentKey', key())}>Turn on remote access</button>`}</div>
    <h2>Account</h2><div class="card"><div class="field"><span>${user.email}</span><button onClick=${signOut}>Sign out</button></div></div></div>`
}
render(html`<${App}/>`, document.getElementById('root'))
