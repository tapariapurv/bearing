# Connect AI agents to Bearing (MCP)

Bearing has an [MCP](https://modelcontextprotocol.io) server, so any AI app or agent that supports MCP can read your plan and act on it: Claude, ChatGPT, Codex, Gemini, Cursor, VS Code, Grok, your own bots, and others. Agents can only do what you allow in **Settings › Agents › Permissions**.

There are two servers:

| | Local | Remote |
|---|---|---|
| URL | `http://127.0.0.1:7319/mcp` | `https://bearing-planner.vercel.app/api/mcp` |
| Reachable from | This Mac only, while Bearing is open | Anywhere, any time |
| Token | **Copy Token** in Settings › Agents › Connect | **Turn On Remote Access**, then copy from Settings › Agents › Remote |
| "Ask each time" | Bearing asks you | Counts as Allow, since nobody is around to ask |

Both servers use the standard Streamable HTTP transport. The remote one accepts MCP versions `2024-11-05` to `2025-11-25`.

## Sign in

Send the token in a header:

```
Authorization: Bearer TOKEN
```

If an app only takes a URL, use **Copy Link** in Settings › Agents › Remote. It copies the remote URL with your key in it (`…/api/mcp?key=bk_…`). This works only for the remote server. Keep the link private, because anyone who has it can use your Bearing. To cut off every agent at once, use **Turn Off** and then turn remote access on again, which makes a new key.

## Set up your app

Replace `TOKEN` with your token. Each example uses the remote server. For the local one, swap in the local URL and local token.

**Claude Code**

```bash
claude mcp add --transport http bearing https://bearing-planner.vercel.app/api/mcp --header "Authorization: Bearer TOKEN"
```

**Claude (web and desktop):** go to Settings › Connectors › Add custom connector and paste the link from **Copy Link**.

**ChatGPT:** turn on developer mode in Settings › Connectors › Advanced, then create a connector. Paste the link from **Copy Link** and choose **No authentication**.

**Codex** (`~/.codex/config.toml`):

```toml
[mcp_servers.bearing]
url = "https://bearing-planner.vercel.app/api/mcp"
bearer_token_env_var = "BEARING_TOKEN"
```

Then run `export BEARING_TOKEN=TOKEN` in your shell.

**Gemini CLI** (`~/.gemini/settings.json`):

```json
{ "mcpServers": { "bearing": { "httpUrl": "https://bearing-planner.vercel.app/api/mcp", "headers": { "Authorization": "Bearer TOKEN" } } } }
```

**Cursor** (`~/.cursor/mcp.json`) and most apps that use an `mcpServers` file:

```json
{ "mcpServers": { "bearing": { "url": "https://bearing-planner.vercel.app/api/mcp", "headers": { "Authorization": "Bearer TOKEN" } } } }
```

**VS Code** (`.vscode/mcp.json`):

```json
{ "servers": { "bearing": { "type": "http", "url": "https://bearing-planner.vercel.app/api/mcp", "headers": { "Authorization": "Bearer TOKEN" } } } }
```

**Grok, model APIs and your own code:** most APIs that support remote MCP servers take a server URL and a header. Pass the remote URL and `Authorization: Bearer TOKEN`, or pass the link as the URL.

**Apps that only run local (stdio) servers:** bridge them with [mcp-remote](https://www.npmjs.com/package/mcp-remote).

```json
{ "mcpServers": { "bearing": { "command": "npx", "args": ["mcp-remote", "https://bearing-planner.vercel.app/api/mcp", "--header", "Authorization: Bearer TOKEN"] } } }
```

## Test it

```bash
curl -s https://bearing-planner.vercel.app/api/mcp -H "Content-Type: application/json" -H "Authorization: Bearer TOKEN" -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
```

If you get `401` with "Bad token", copy the token again. A new token or key stops the old one from working.

## Tools

Each tool belongs to a permission. Tools whose permission is **Off** are hidden from agents.

| Permission | Tool | What it does |
|---|---|---|
| Read | `get_overview` | Season goals, classes with their sub-projects, projects, and open task counts. Call this first to learn the names. |
| Read | `list_tasks` | List tasks, open ones by default. Filter by class or project, sub-project, goal, text or due date. |
| Read | `get_task` | One task with every field. |
| Read | `list_goals` | Season goals with why, metric, weekly hours, status, notes and hours focused this week. |
| Read | `get_schedule` | Time blocks, day by day, for up to 14 days. |
| Read | `get_journal` | Journal entries between two dates. |
| Read | `get_focus_stats` | Focus hours, sessions, quality and distractions per goal. |
| Read | `search` | Search tasks, goals, classes, projects and the journal. |
| Write | `add_task` | Add a task. It syncs to Todoist. |
| Write | `add_area` | Create a class or a project. |
| Write | `add_sub_project` | Create a sub-project inside a class. |
| Write | `time_block` | Block time for a task. |
| Write | `write_journal` | Add to or replace a day's journal entry. |
| Edit | `update_task` | Change a task's fields. |
| Edit | `complete_task` | Mark a task done or not done. |
| Edit | `update_area` | Rename a class or project, change its kind, goal, icon (an SF Symbol name), color or status. |
| Edit | `update_goal` | Change a goal's fields. |
| Delete | `delete_task` | Delete a task. |
| Delete | `delete_area` | Remove a class or project. Its tasks stay, unsorted. |
| Delete | `delete_block` | Remove a time block. |

Calendar events stay on your devices. Agents see your time blocks, not your calendar.
