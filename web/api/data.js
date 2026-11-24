// The web app's data endpoint. Signs in with the web key from Bearing › Settings › Open on the Web,
// a separate secret from the agent key so agents can't bypass their permissions through it.
import { account, load, save } from './mcp.js'

export default async function handler(req, res) {
  const a = await account(req, 'webKey').catch(() => null)
  if (!a) return res.status(401).json({ error: 'This link has expired. Open Bearing on the web again from the Mac app.' })
  if (req.method === 'GET') return res.json({ email: a.email, data: a.data, updateTime: a.updateTime })
  if (req.method !== 'PUT') return res.status(405).end()
  try { await save(a.email, req.body.data, req.body.updateTime); res.json(await load(a.email)) }
  catch (e) { res.status(e.status === 400 || e.status === 412 ? 409 : 500).json({ error: e.message, ...(await load(a.email)) }) }
}
