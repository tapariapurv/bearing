// Bearing on the web: the Mac app minus what a browser can't do (Coach AI, voice capture, site blocking,
// Calendar and Todoist calls). Reads and writes the same synced document as the apps through /api/data.
import { html, render, useState, useEffect } from 'https://esm.sh/htm@3.1.1/preact/standalone'
import * as C from './core.js'

const PAGES = ['Today', 'Week', 'Tasks', 'Goals', 'Focus', 'Journal', 'Insights', 'Settings']
const clock = d => new Date(d).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' })
const dayName = d => new Date(d).toLocaleDateString([], { weekday: 'long', month: 'short', day: 'numeric' })
const sameDay = (a, b) => C.dayKey(a) === C.dayKey(b)
const ls = (k, v) => { try { if (v === undefined) return JSON.parse(localStorage.getItem(k)); localStorage.setItem(k, JSON.stringify(v)) } catch { return null } }
// The Mac app opens /#t=<web token>; the token lives in this browser only (a URL fragment never reaches a server).
if (location.hash.startsWith('#t=')) { ls('token', location.hash.slice(3)); history.replaceState(null, '', '/') }
let user, data, rev, rerender = () => {}, busy = 0
const api = (method, body) => fetch('/api/data', { method, headers: { authorization: `Bearer ${ls('token')}`, 'content-type': 'application/json' }, body: body && JSON.stringify(body) })
  .then(async r => { const j = await r.json(); if (r.status === 401) { ls('token', null); user = null } else if (j.data) { user = { email: j.email || user?.email }; data = C.fill(j.data); rev = j.updateTime }
    else data = { error: j.error }; rerender(); return r.status })
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
let toastT; function toast(t) { const el = document.querySelector('.toast') || document.body.appendChild(Object.assign(document.createElement('div'), { className: 'toast' })); el.textContent = t; el.hidden = false; clearTimeout(toastT); toastT = setTimeout(() => el.hidden = true, 2500) }

// Notifications: block start, focus end, tasks due today. Work while a Bearing tab is open.
const sw = 'serviceWorker' in navigator ? navigator.serviceWorker.register('sw.js') : null
async function notify(title, body) {
  if (ls('notify') === false || Notification?.permission !== 'granted') return
  const r = await sw?.catch(() => null); r ? r.showNotification(title, { body, icon: 'icon.png', tag: title }) : new Notification(title, { body, icon: 'icon.png' })
}
setInterval(() => {
  if (!data) return
  const now = Date.now(), seen = ls('seen') || {}
  for (const b of data.blocks) { const s = +new Date(b.start); if (s > now - 60000 && s <= now + 60000 && !seen[b.id]) { seen[b.id] = 1; notify(`Starting: ${b.title}`, `${clock(b.start)} – ${clock(b.end)}`) } }
  const k = C.dayKey(), due = data.tasks.filter(t => !t.done && t.due && C.dayKey(t.due) <= k).length
  if (due && !seen[k] && new Date().getHours() >= (data.prefs.dayStart ?? 9)) { seen[k] = 1; notify(`${due} task${due > 1 ? 's' : ''} due today`, 'Open Bearing to plan them') }
  const f = ls('focus'); if (f && !f.paused && !f.told && now >= f.start + f.minutes * 60000) { f.told = 1; ls('focus', f); notify('Focus session done', f.title) }
  ls('seen', Object.fromEntries(Object.entries(seen).slice(-200)))
}, 20000)

function App() {
  const [, tick] = useState(0), [page, setPage] = useState(location.hash.slice(1) || 'Today')
  rerender = () => tick(n => n + 1)
  useEffect(() => { ls('token') ? api('GET').catch(e => { data = { error: e.message }; rerender() }) : (user = null, rerender()) }, [])
  useEffect(() => { const f = () => setPage(location.hash.slice(1) || 'Today'); addEventListener('hashchange', f); return () => removeEventListener('hashchange', f) }, [])
  const u = user
  if (u === undefined && ls('token')) return null
  if (!u) return html`<div class="login"><div><img src="icon.png" alt=""/><h1>Bearing</h1><p class="sub">Goals, tasks, focus and reflection, synced with the Mac and iPhone apps.</p>
    <p class="sub">To sign in, open Bearing on your Mac and choose<br/><b>Settings › Agents › Open Bearing on the Web</b>.</p></div></div>`
  if (!data || data.error) return html`<div class="login"><div><h1>${data?.error ? 'Can\'t open your data' : 'Loading…'}</h1><p class="sub">${data?.error || ''}</p>${data?.error && html`<button onClick=${signOut}>Sign out</button>`}</div></div>`
  const P = { Today, Week, Tasks, Goals, Focus, Journal, Insights, Settings }[page] || Today
  return html`<div class="app"><nav><div class="logo"><img src="icon.png" alt=""/>Bearing</div>
    ${PAGES.map(p => html`<a href=${'#' + p} class=${p === page ? 'on' : ''}>${p}</a>`)}<div class="me">${u.email}</div></nav><main><${P}/></main></div>`
}

function TaskRow({ t }) {
  const [open, setOpen] = useState(false), area = data.areas.find(a => a.id === t.areaID)
  const ch = (k, v) => save(d => C.updateTask(d, C.task(d, t.id), { [k]: v }))
  return html`<div class="row"><input type="checkbox" checked=${t.done} onChange=${() => save(d => C.setDone(d, C.task(d, t.id)))}/>
    <div class="grow"><div class=${t.done ? 'done' : ''} style="cursor:pointer" onClick=${() => setOpen(!open)}>${t.title}</div>
      <div class="tag ${'p' + t.priority}">${[area?.name, t.sub, C.goalTitle(data, t.goalID), t.due && new Date(t.due).toLocaleDateString([], { month: 'short', day: 'numeric' }), t.priority > 1 && 'P' + (5 - t.priority)].filter(Boolean).join(' · ')}</div>
      ${open && html`<div class="grid" style="margin:10px 0">
        <input value=${t.title} onChange=${e => ch('title', e.target.value)}/>
        <input type="date" value=${t.due ? C.dayKey(t.due) : ''} onChange=${e => ch('due', C.parseDay(e.target.value))}/>
        <select value=${t.priority} onChange=${e => ch('priority', +e.target.value)}>${[4, 3, 2, 1].map(p => html`<option value=${p}>${p === 1 ? 'Normal' : 'P' + (5 - p)}</option>`)}</select>
        <select value=${t.areaID || ''} onChange=${e => save(d => C.updateTask(d, C.task(d, t.id), { areaID: e.target.value || null, sub: null }))}><option value="">No class or project</option>${data.areas.map(a => html`<option value=${a.id}>${a.name}</option>`)}</select>
        ${area?.subs?.length && html`<select value=${t.sub || ''} onChange=${e => ch('sub', e.target.value || null)}><option value="">No sub-project</option>${area.subs.map(s => html`<option>${s}</option>`)}</select>`}
        <select value=${t.goalID || ''} onChange=${e => ch('goalID', e.target.value || null)}><option value="">No goal</option>${C.goals(data).map(g => html`<option value=${g.id}>${g.title}</option>`)}</select>
        <textarea style="grid-column:1/-1;min-height:70px" placeholder="Notes" onChange=${e => ch('notes', e.target.value)}>${t.notes}</textarea>
        ${t.resources?.map(r => html`<a href=${r} target="_blank" rel="noopener" class="tag">${r}</a>`)}</div>`}</div>
    <button class="link" title="Block time for this" onClick=${() => { const m = data.prefs.blockMinutes || 60, s = C.nextFree(data, m); s ? save(d => C.addBlock(d, { title: t.title, start: s, minutes: m, goalID: t.goalID, taskID: t.id })) : toast('No free slot in the next two weeks'); s && toast(`Blocked ${dayName(s)} ${clock(s)}`) }}>Block</button>
    <button class="link" title="Delete" onClick=${() => confirm(`Delete "${t.title}"?`) && save(d => C.deleteTask(d, C.task(d, t.id)))}>✕</button></div>`
}
function AddTask({ extra = {} }) {
  const [v, setV] = useState(''), [a, setA] = useState('')
  const go = e => { e.preventDefault(); if (!v.trim()) return; save(d => C.addTask(d, { title: v.trim(), areaID: a || undefined, ...extra })); setV('') }
  return html`<form class="add" onSubmit=${go}><input placeholder="Add a task" value=${v} onInput=${e => setV(e.target.value)}/>
    <select style="width:180px" value=${a} onChange=${e => setA(e.target.value)}><option value="">No class or project</option>${data.areas.map(x => html`<option value=${x.id}>${x.name}</option>`)}</select><button class="primary">Add</button></form>`
}
const Blocks = ({ list }) => list.length ? html`<div class="card">${list.map(b => html`<div class="row"><span class="tag" style="width:130px">${clock(b.start)} – ${clock(b.end)}</span><div class="grow">${b.title}</div>
  <button class="link" onClick=${() => save(d => { d.blocks = d.blocks.filter(x => x.id !== b.id) })}>✕</button></div>`)}</div>` : html`<p class="sub">Nothing blocked.</p>`
const blocksOn = day => data.blocks.filter(b => sameDay(b.start, day)).sort((a, b) => a.start < b.start ? -1 : 1)

function Today() {
  const k = C.dayKey(), due = data.tasks.filter(t => !t.done && t.due && C.dayKey(t.due) <= k)
  return html`<h1>${dayName(new Date())}</h1><p class="sub">${data.compass || data.seasonName}</p>
    <h2>Schedule</h2><${Blocks} list=${blocksOn(new Date())}/>
    <h2>Due today and overdue</h2><${AddTask} extra=${{ due: new Date() }}/>
    <div class="card">${due.length ? due.map(t => html`<${TaskRow} t=${t} key=${t.id}/>`) : html`<p class="sub" style="margin:10px 0">All clear.</p>`}</div>`
}
function Week() {
  const days = [...Array(7)].map((_, i) => { const d = new Date(); d.setDate(d.getDate() + i); return d })
  return html`<h1>This week</h1><p class="sub">Time blocks and tasks due, day by day.</p>${days.map(d => html`<h2>${dayName(d)}</h2><${Blocks} list=${blocksOn(d)}/>
    ${data.tasks.filter(t => !t.done && t.due && sameDay(t.due, d)).map(t => html`<div class="card"><${TaskRow} t=${t} key=${t.id}/></div>`)}`)}`
}
function Tasks() {
  const [f, setF] = useState(ls('area') || ''), [done, setDone] = useState(false)
  const list = data.tasks.filter(t => (done || !t.done) && (!f || t.areaID === f)).sort((a, b) => (a.due || '9') < (b.due || '9') ? -1 : 1)
  const groups = [...data.areas.filter(a => !f || a.id === f), { id: undefined, name: 'Unsorted' }].map(a => [a.name, list.filter(t => t.areaID === a.id || (!a.id && !data.areas.some(x => x.id === t.areaID)))]).filter(g => g[1].length)
  return html`<h1>Tasks</h1><p class="sub">${data.tasks.filter(t => !t.done).length} open · synced with Todoist through the Mac app</p>
    <div class="add"><select value=${f} onChange=${e => { setF(e.target.value); ls('area', e.target.value) }}><option value="">All classes and projects</option>${data.areas.map(a => html`<option value=${a.id}>${a.isClass ? 'Class' : 'Project'}: ${a.name}</option>`)}</select>
      <label style="display:flex;gap:6px;align-items:center;white-space:nowrap"><input type="checkbox" checked=${done} onChange=${() => setDone(!done)}/>Show done</label></div>
    <${AddTask}/>${groups.map(([n, l]) => html`<h2>${n}</h2><div class="card">${l.map(t => html`<${TaskRow} t=${t} key=${t.id}/>`)}</div>`)}`
}
function Goals() {
  const wk = new Date(Date.now() - 7 * 864e5), up = (g, k, v) => save(d => { d.goals.find(x => x.id === g.id)[k] = v })
  return html`<h1>Goals</h1><p class="sub">${data.seasonName} · ${data.seasonWeeks} weeks</p>${C.goals(data).map(g => {
    const h = C.focused(data, g.id, wk) / 3600
    return html`<div class="card" style="padding:14px"><div class="row" style="border:0;padding:0"><b class="grow">${g.title}</b>
      <select style="width:150px" value=${g.status} onChange=${e => up(g, 'status', e.target.value)}>${[['none', 'Not reviewed'], ['onTrack', 'On track'], ['adjust', 'Adjust'], ['offTrack', 'Off track']].map(([v, l]) => html`<option value=${v}>${l}</option>`)}</select></div>
      <p class="sub" style="margin:6px 0">${g.why}</p><div class="bar"><i style=${`width:${Math.min(100, h / g.weeklyHours * 100)}%`}/></div>
      <p class="tag">${h.toFixed(1)} of ${g.weeklyHours} h this week · ${data.tasks.filter(t => t.goalID === g.id && !t.done).length} open tasks${g.metric && ' · Done when: ' + g.metric}</p>
      <textarea style="min-height:60px" placeholder="Next actions" onChange=${e => up(g, 'notes', e.target.value)}>${g.notes}</textarea></div>`
  })}`
}
function Focus() {
  const [f, setF] = useState(ls('focus')), [, t] = useState(0), set = v => { ls('focus', v); setF(v) }
  useEffect(() => { const i = setInterval(() => t(n => n + 1), 1000); return () => clearInterval(i) }, [])
  const [goal, setGoal] = useState(''), [min, setMin] = useState(data.prefs.timerMinutes || 25)
  if (!f) return html`<h1>Focus</h1><p class="sub">A timed session, saved to your focus history.</p><div class="card" style="padding:14px"><div class="grid">
    <select value=${goal} onChange=${e => setGoal(e.target.value)}><option value="">No goal</option>${C.goals(data).map(g => html`<option value=${g.id}>${g.title}</option>`)}</select>
    <input type="number" min="5" max="180" value=${min} onInput=${e => setMin(+e.target.value)}/></div>
    <div class="center" style="margin:16px 0"><button class="primary" onClick=${() => { Notification?.permission === 'default' && Notification.requestPermission(); set({ start: Date.now(), minutes: min, goalID: goal, title: C.goalTitle(data, goal) || 'Focus', paused: 0, pausedAt: null, distractions: 0 }) }}>Start ${min} min</button></div></div>`
  const now = f.pausedAt || Date.now(), el = (now - f.start) / 1000 - f.paused, left = Math.max(0, f.minutes * 60 - el)
  const stop = () => { if (el > 60) save(d => d.sessions.push({ id: C.uuid(), title: f.title, ...(f.goalID && { goalID: f.goalID }), start: C.iso(f.start), seconds: Math.round(Math.min(el, f.minutes * 60)), pausedSeconds: Math.round(f.paused), distractions: f.distractions })); set(null) }
  return html`<h1>${f.title}</h1><div class="timer">${Math.floor(left / 60)}:${String(Math.floor(left % 60)).padStart(2, '0')}</div><div class="center">
    ${f.pausedAt ? html`<button onClick=${() => set({ ...f, paused: f.paused + (Date.now() - f.pausedAt) / 1000, pausedAt: null })}>Resume</button>` : html`<button onClick=${() => set({ ...f, pausedAt: Date.now() })}>Pause</button>`}
    <button onClick=${() => set({ ...f, distractions: f.distractions + 1 })}>Distracted (${f.distractions})</button><button class="primary" onClick=${stop}>${left ? 'End' : 'Save'} session</button></div>`
}
function Journal() {
  const [k, setK] = useState(C.dayKey()), e = data.journal.find(j => j.id === k)
  return html`<h1>Journal</h1><div class="add"><input type="date" value=${k} onChange=${x => setK(x.target.value || C.dayKey())}/></div>
    ${e?.prompt && html`<p class="sub">${e.prompt}</p>`}<textarea key=${k} placeholder="How did today go?" onChange=${x => save(d => C.writeJournal(d, k, x.target.value, true))}>${e?.text || ''}</textarea>
    <h2>Recent</h2>${data.journal.filter(j => j.text).sort((a, b) => a.id < b.id ? 1 : -1).slice(0, 10).map(j => html`<div class="card" style="padding:12px;cursor:pointer" onClick=${() => setK(j.id)}><b>${dayName(C.parseDay(j.id))}</b><p class="tag">${j.text.slice(0, 200)}</p></div>`)}`
}
function Insights() {
  const wk = new Date(Date.now() - 7 * 864e5), ss = data.sessions.filter(s => new Date(s.start) >= wk), hrs = ss.reduce((a, s) => a + s.seconds, 0) / 3600
  return html`<h1>Insights</h1><p class="sub">The last 7 days.</p><div class="grid">
    ${[['Focused', hrs.toFixed(1) + ' h'], ['Sessions', ss.length], ['Avg quality', ss.length ? Math.round(ss.reduce((a, s) => a + C.quality(s), 0) / ss.length) + '%' : '–'], ['Blocks', data.blocks.filter(b => new Date(b.start) >= wk && new Date(b.start) <= new Date()).length]].map(([l, v]) => html`<div class="card" style="padding:14px"><div class="tag">${l}</div><div style="font-size:28px;font-weight:700">${v}</div></div>`)}</div>
    <h2>Hours by goal</h2><div class="card">${C.goals(data).map(g => { const h = C.focused(data, g.id, wk) / 3600; return html`<div class="row"><div class="grow">${g.title}<div class="bar"><i style=${`width:${Math.min(100, h / g.weeklyHours * 100)}%`}/></div></div><span class="tag">${h.toFixed(1)} / ${g.weeklyHours} h</span></div>` })}</div>`
}
function Settings() {
  const p = data.prefs, set = (k, v) => save(d => { d.prefs[k] = v }), [n, setN] = useState(ls('notify') !== false && globalThis.Notification?.permission === 'granted')
  const token = p.agentKey && `bk_${btoa(user.email).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')}_${p.agentKey}`, url = location.origin + '/api/mcp'
  const key = () => [...crypto.getRandomValues(new Uint8Array(32))].map(b => b.toString(16).padStart(2, '0')).join('')
  const copy = t => navigator.clipboard.writeText(t).then(() => toast('Copied'))
  const num = (k, l, def, min, max, step = 1) => html`<div class="field"><span>${l}</span><input type="number" min=${min} max=${max} step=${step} value=${p[k] ?? def} onChange=${e => set(k, +e.target.value)}/></div>`
  return html`<h1>Settings</h1><p class="sub">Coach, voice capture, site blocking, Calendar and Todoist sync run in the Mac and iPhone apps; changes here reach them within a minute.</p>
    <h2>Notifications</h2><div class="card"><div class="field"><span>Remind me when blocks start, focus ends and tasks are due (while a Bearing tab is open)</span>
      <input type="checkbox" checked=${n} onChange=${async () => { if (n) { ls('notify', false); setN(false) } else { const r = await Notification.requestPermission(); ls('notify', r === 'granted'); setN(r === 'granted'); r !== 'granted' && toast('Allow notifications for this site in your browser') } }}/></div></div>
    <h2>Planning</h2><div class="card">${num('blockMinutes', 'Time block length (minutes)', 60, 15, 240, 15)}${num('dayStart', 'Day starts at (hour)', 9, 0, 23)}${num('dayEnd', 'Day ends at (hour)', 19, 1, 24)}
      <div class="field"><span>Tag Todoist tasks with class and project</span><input type="checkbox" checked=${p.labelSync !== false} onChange=${e => set('labelSync', e.target.checked)}/></div></div>
    <h2>Agent permissions</h2><div class="card">${C.SCOPES.map(s => html`<div class="field"><span>${s.title}<div class="tag">${s.detail}</div></span>
      <select value=${C.mode(data, s.key)} onChange=${e => set('agentAccess', { ...(p.agentAccess || {}), [s.key]: e.target.value })}>${[['off', 'Off'], ['ask', 'Ask each time'], ['allow', 'Allow']].map(([v, l]) => html`<option value=${v}>${l}</option>`)}</select></div>`)}</div>
    <h2>Remote MCP server</h2><div class="card" style="padding:14px">${token ? html`<p class="tag">Any agent, server or device can connect. "Ask each time" counts as Off here, since nobody is there to ask.</p>
      <p><code>claude mcp add --transport http bearing ${url} --header "Authorization: Bearer ${token}"</code></p>
      <div class="center" style="justify-content:flex-start"><button onClick=${() => copy(`claude mcp add --transport http bearing ${url} --header "Authorization: Bearer ${token}"`)}>Copy command</button>
      <button onClick=${() => copy(token)}>Copy token</button><button onClick=${() => confirm('Disconnect every remote agent?') && set('agentKey', key())}>New token</button><button onClick=${() => set('agentKey', null)}>Turn off</button></div>`
      : html`<button class="primary" onClick=${() => set('agentKey', key())}>Turn on remote access</button>`}</div>
    <h2>Account</h2><div class="card"><div class="field"><span>${user.email}</span><button onClick=${signOut}>Sign out</button></div></div>`
}
render(html`<${App}/>`, document.getElementById('root'))
