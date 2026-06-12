// PlutoLand — the workspace hub: a file browser + tabbed notebooks, all running on a
// stock Pluto server. Every tab is the UNMODIFIED Pluto editor in an iframe (its own
// websocket, its own state); the hub itself only talks to existing server endpoints:
//   GET  ./api/v1/workspace        workspace file tree (404 → no workspace open yet)
//   POST ./api/v1/workspace/open   open a folder as the workspace (VS Code "Open Folder")
//   GET  ./api/v1/browse           directory listing for the folder picker
//   GET  ./api/v1/notebooks        running notebooks
//   POST ./open?path=…             open a notebook (Safe preview), returns its id
//   POST ./new                     new notebook, returns its id
//   POST ./move?id=…&newpath=…     rename/move (used to place new notebooks in the workspace)
//   POST ./shutdown?id=…           stop a notebook session
import { html, render, useState, useEffect, useCallback, useRef } from "./imports/Preact.js"

const get_text = async (url, opts) => {
    const r = await fetch(url, opts)
    if (!r.ok) throw new Error(`${url} → ${r.status}`)
    return await r.text()
}
const get_json = async (url, opts) => {
    const r = await fetch(url, opts)
    if (!r.ok) throw new Error(`${url} → ${r.status}`)
    return await r.json()
}

const basename = (p) => p.split("/").pop()

const RECENT_KEY = "plutoland recent workspaces"
const get_recent_workspaces = () => {
    try {
        const r = JSON.parse(localStorage.getItem(RECENT_KEY) ?? "[]")
        return Array.isArray(r) ? r : []
    } catch {
        return []
    }
}
const remember_workspace = (path) => {
    localStorage.setItem(RECENT_KEY, JSON.stringify([path, ...get_recent_workspaces().filter((p) => p !== path)].slice(0, 8)))
}

const FileEntry = ({ entry, on_open_notebook, depth }) => {
    const [open, set_open] = useState(false)
    if (entry.type === "dir") {
        return html`<li class="dir ${open ? "open" : ""}">
            <button class="entry" onClick=${() => set_open(!open)}><span class="icon chevron"></span>${entry.name}</button>
            ${open
                ? html`<ul>
                      ${entry.children.map(
                          (c) => html`<${FileEntry} key=${c.path} entry=${c} on_open_notebook=${on_open_notebook} depth=${depth + 1} />`
                      )}
                  </ul>`
                : null}
        </li>`
    }
    if (entry.type === "notebook") {
        return html`<li class="notebook">
            <button class="entry" title=${entry.path} onClick=${() => on_open_notebook(entry.path)}>
                <span class="icon pluto-dot"></span>${entry.name}
            </button>
        </li>`
    }
    return html`<li class="file"><span class="entry plain" title=${entry.path}><span class="icon"></span>${entry.name}</span></li>`
}

/** The VS Code "Open Folder" experience: browse the server's filesystem, pick a folder. */
const WorkspaceOpener = ({ on_opened }) => {
    const [listing, set_listing] = useState(/** @type {{path: String, parent: String, dirs: Array<String>}?} */ (null))
    const [error, set_error] = useState(/** @type {String?} */ (null))

    const browse = useCallback(async (path) => {
        try {
            set_listing(await get_json(path == null ? "./api/v1/browse" : `./api/v1/browse?path=${encodeURIComponent(path)}`))
            set_error(null)
        } catch (e) {
            set_error(String(e))
        }
    }, [])

    useEffect(() => {
        browse(null)
    }, [])

    const open_workspace = useCallback(
        async (path) => {
            try {
                const result = await get_json(`./api/v1/workspace/open?path=${encodeURIComponent(path)}`, { method: "POST" })
                remember_workspace(result.root)
                on_opened()
            } catch (e) {
                set_error(String(e))
            }
        },
        [on_opened]
    )

    const recent = get_recent_workspaces()

    return html`<div class="workspace-opener">
        <div class="bubble opener-card">
            <h1>Pluto<span class="land-accent">Land</span></h1>
            <p class="subtitle">Open a folder as your workspace — notebooks inside it open as tabs.</p>

            ${recent.length > 0
                ? html`<section>
                      <h2>Recent</h2>
                      <ul>
                          ${recent.map(
                              (p) => html`<li>
                                  <button class="entry" title=${p} onClick=${() => open_workspace(p)}>
                                      <span class="icon">🗂</span>${basename(p)}<span class="entry-detail">${p}</span>
                                  </button>
                              </li>`
                          )}
                      </ul>
                  </section>`
                : null}

            <section>
                <h2>Browse</h2>
                ${listing == null
                    ? html`<p class="subtitle">loading…</p>`
                    : html`
                          <p class="current-path" title=${listing.path}>${listing.path}</p>
                          <ul class="browse-list">
                              ${listing.parent !== listing.path
                                  ? html`<li><button class="entry" onClick=${() => browse(listing.parent)}><span class="icon">↰</span>..</button></li>`
                                  : null}
                              ${listing.dirs.map(
                                  (name) => html`<li>
                                      <button class="entry" onClick=${() => browse(`${listing.path}/${name}`)}><span class="icon">▸</span>${name}</button>
                                  </li>`
                              )}
                          </ul>
                          <button class="new-notebook open-this-folder" onClick=${() => open_workspace(listing.path)}>
                              Open <strong>${basename(listing.path) || listing.path}</strong> as workspace
                          </button>
                      `}
            </section>
            ${error == null ? null : html`<p class="opener-error">${error}</p>`}
        </div>
    </div>`
}

const Land = () => {
    const [workspace, set_workspace] = useState(/** @type {{root: String, entries: Array}?} */ (null))
    const [no_workspace, set_no_workspace] = useState(false)
    const [running, set_running] = useState(/** @type {Array<{notebook_id: String, path: String}>} */ ([]))
    const [tabs, set_tabs] = useState(/** @type {Array<{id: String, path: String}>} */ ([]))
    const [active, set_active] = useState(/** @type {String?} */ (null))
    const [error, set_error] = useState(/** @type {String?} */ (null))
    const [sidebar_width, set_sidebar_width] = useState(() => Number(localStorage.getItem("plutoland sidebar width")) || 290)
    const [sidebar_hidden, set_sidebar_hidden] = useState(() => localStorage.getItem("plutoland sidebar hidden") === "true")
    const auto_tabbed = useRef(false)

    useEffect(() => {
        localStorage.setItem("plutoland sidebar width", String(sidebar_width))
        localStorage.setItem("plutoland sidebar hidden", String(sidebar_hidden))
    }, [sidebar_width, sidebar_hidden])

    const add_tab = useCallback((id, path) => {
        set_tabs((tabs) => (tabs.some((t) => t.id === id) ? tabs : [...tabs, { id, path }]))
        set_active(id)
    }, [])

    const refresh = useCallback(async () => {
        try {
            const ws_response = await fetch("./api/v1/workspace")
            if (ws_response.status === 404) {
                set_no_workspace(true)
                set_workspace(null)
            } else if (ws_response.ok) {
                set_no_workspace(false)
                set_workspace(await ws_response.json())
            }
            const running_now = await get_json("./api/v1/notebooks")
            set_running(running_now)
            // on first load, show already-running notebooks as tabs (e.g. one passed via Pluto.run(notebook=…))
            if (!auto_tabbed.current) {
                auto_tabbed.current = true
                running_now.forEach((nb) => add_tab(nb.notebook_id, nb.path))
            }
            set_error(null)
        } catch (e) {
            set_error(String(e))
        }
    }, [add_tab])

    useEffect(() => {
        refresh()
        const interval = setInterval(refresh, 10_000)
        return () => clearInterval(interval)
    }, [])

    const start_sidebar_resize = useCallback((e) => {
        e.preventDefault()
        document.body.classList.add("resizing") // disables pointer events on the iframes so the drag isn't swallowed
        const move = (ev) => set_sidebar_width(Math.max(180, Math.min(560, ev.clientX - 12)))
        const up = () => {
            document.body.classList.remove("resizing")
            window.removeEventListener("pointermove", move)
            window.removeEventListener("pointerup", up)
        }
        window.addEventListener("pointermove", move)
        window.addEventListener("pointerup", up)
    }, [])

    const open_notebook = useCallback(
        async (path) => {
            try {
                const id = await get_text(`./open?path=${encodeURIComponent(path)}`, { method: "POST" })
                add_tab(id, path)
                refresh()
            } catch (e) {
                set_error(String(e))
            }
        },
        [add_tab, refresh]
    )

    const new_notebook = useCallback(async () => {
        if (workspace == null) return
        const name = prompt("Notebook file name (created in the workspace):", "new notebook.jl")
        if (name == null) return
        try {
            const id = await get_text("./new", { method: "POST" })
            const newpath = `${workspace.root}/${name.endsWith(".jl") ? name : name + ".jl"}`
            await get_text(`./move?id=${encodeURIComponent(id)}&newpath=${encodeURIComponent(newpath)}`, { method: "POST" })
            add_tab(id, newpath)
            refresh()
        } catch (e) {
            set_error(String(e))
        }
    }, [workspace, add_tab, refresh])

    const close_tab = useCallback((id) => {
        // closing a tab does NOT shut down the notebook (JupyterHub semantics) — it keeps running, listed under "Running"
        set_tabs((tabs) => {
            const remaining = tabs.filter((t) => t.id !== id)
            set_active((a) => (a === id ? (remaining.length > 0 ? remaining[remaining.length - 1].id : null) : a))
            return remaining
        })
    }, [])

    const shutdown_notebook = useCallback(
        async (id) => {
            if (!confirm("Shut down this notebook session? The file stays on disk; outputs are cached.")) return
            try {
                await get_text(`./shutdown?id=${encodeURIComponent(id)}`, { method: "POST" })
                close_tab(id)
                refresh()
            } catch (e) {
                set_error(String(e))
            }
        },
        [close_tab, refresh]
    )

    // no workspace yet → the whole page is the opener (the VS Code "Open Folder" screen)
    if (no_workspace) {
        return html`<${WorkspaceOpener} on_opened=${refresh} />`
    }

    return html`
        <div id="land">
            ${sidebar_hidden
                ? html`<button id="sidebar-reopen" title="Show sidebar" onClick=${() => set_sidebar_hidden(false)}>☰</button>`
                : html`<aside style=${`width: ${sidebar_width}px`}>
                <header class="bubble">
                    <h1>Pluto<span class="land-accent">Land</span></h1>
                    <p class="workspace-root" title=${workspace?.root ?? ""}>${workspace == null ? "loading…" : basename(workspace.root)}</p>
                    <button class="sidebar-hide" title="Hide sidebar" onClick=${() => set_sidebar_hidden(true)}>⟨</button>
                </header>
                <section class="files bubble">
                    <h2>Workspace</h2>
                    <ul class="tree">
                        ${workspace == null
                            ? null
                            : workspace.entries.map(
                                  (e) => html`<${FileEntry} key=${e.path} entry=${e} on_open_notebook=${open_notebook} depth=${0} />`
                              )}
                    </ul>
                </section>
                <section class="running bubble">
                    <h2>Running</h2>
                    <ul>
                        ${running.map(
                            (nb) => html`<li>
                                <button class="entry" title=${nb.path} onClick=${() => add_tab(nb.notebook_id, nb.path)}>
                                    <span class="icon running-dot"></span>${basename(nb.path)}
                                </button>
                                <button class="shutdown" title="Shut down this notebook" onClick=${() => shutdown_notebook(nb.notebook_id)}>✕</button>
                            </li>`
                        )}
                    </ul>
                </section>
                <footer>
                    <button class="new-notebook" onClick=${new_notebook}>+ New notebook</button>
                </footer>
            </aside>`}
            ${sidebar_hidden ? null : html`<div id="sidebar-resizer" onPointerDown=${start_sidebar_resize}></div>`}
            <main>
                <nav id="tabs" class=${tabs.length === 0 ? "empty" : ""}>
                    ${tabs.map(
                        (t) => html`<div class="tab ${t.id === active ? "active" : ""}" key=${t.id}>
                            <button class="title" title=${t.path} onClick=${() => set_active(t.id)}>${basename(t.path)}</button>
                            <button class="close" title="Close tab (notebook keeps running)" onClick=${() => close_tab(t.id)}>×</button>
                        </div>`
                    )}
                </nav>
                <div id="frames">
                    ${tabs.map(
                        // every tab is the stock Pluto editor; iframes stay mounted so switching tabs never loses state
                        (t) => html`<iframe key=${t.id} src=${`./edit?id=${t.id}`} class=${t.id === active ? "active" : ""}></iframe>`
                    )}
                    ${tabs.length === 0
                        ? html`<div class="empty-state">
                              <p>Open a notebook from the workspace on the left, or create a new one.</p>
                              <p class="hint">Agents can work here too: edit any notebook file, or use <code>pluto-collab</code>.</p>
                          </div>`
                        : null}
                </div>
            </main>
            ${error == null ? null : html`<div id="land-error">${error}</div>`}
        </div>
    `
}

render(html`<${Land} />`, document.querySelector("#land-app"))
