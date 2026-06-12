// PlutoLand — the workspace hub: a file browser + tabbed notebooks, all running on a
// stock Pluto server. Every tab is the UNMODIFIED Pluto editor in an iframe (its own
// websocket, its own state); the hub itself only talks to existing server endpoints:
//   GET  ./api/v1/workspace   workspace file tree
//   GET  ./api/v1/notebooks   running notebooks
//   POST ./open?path=…        open a notebook, returns its id
//   POST ./new                new notebook, returns its id
//   POST ./move?id=…&newpath=…  rename/move (used to place new notebooks in the workspace)
//   GET  ./shutdown?id=…      stop a notebook session
import { html, render, useState, useEffect, useCallback } from "./imports/Preact.js"

const get_text = async (url, opts) => {
    const r = await fetch(url, opts)
    if (!r.ok) throw new Error(`${url} → ${r.status}`)
    return await r.text()
}
const get_json = async (url) => {
    const r = await fetch(url)
    if (!r.ok) throw new Error(`${url} → ${r.status}`)
    return await r.json()
}

const FileEntry = ({ entry, on_open_notebook, depth }) => {
    const [open, set_open] = useState(depth < 1)
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

const Land = () => {
    const [workspace, set_workspace] = useState(/** @type {{root: String, entries: Array}?} */ (null))
    const [running, set_running] = useState(/** @type {Array<{notebook_id: String, path: String}>} */ ([]))
    const [tabs, set_tabs] = useState(/** @type {Array<{id: String, path: String}>} */ ([]))
    const [active, set_active] = useState(/** @type {String?} */ (null))
    const [error, set_error] = useState(/** @type {String?} */ (null))

    const refresh = useCallback(async () => {
        try {
            set_workspace(await get_json("./api/v1/workspace"))
            set_running(await get_json("./api/v1/notebooks"))
            set_error(null)
        } catch (e) {
            set_error(String(e))
        }
    }, [])

    useEffect(() => {
        refresh()
        const interval = setInterval(refresh, 10_000)
        return () => clearInterval(interval)
    }, [])

    const add_tab = useCallback((id, path) => {
        set_tabs((tabs) => (tabs.some((t) => t.id === id) ? tabs : [...tabs, { id, path }]))
        set_active(id)
    }, [])

    const open_notebook = useCallback(
        async (path) => {
            try {
                const id = await get_text(`./open?path=${encodeURIComponent(path)}&execution_allowed=true`, { method: "POST" })
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

    const close_tab = useCallback(
        (id) => {
            // closing a tab does NOT shut down the notebook (JupyterHub semantics) — it keeps running, listed under "Running"
            set_tabs((tabs) => {
                const remaining = tabs.filter((t) => t.id !== id)
                set_active((a) => (a === id ? (remaining.length > 0 ? remaining[remaining.length - 1].id : null) : a))
                return remaining
            })
        },
        []
    )

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

    const basename = (p) => p.split("/").pop()

    return html`
        <div id="land">
            <aside>
                <header>
                    <h1>Pluto<span class="land-accent">Land</span></h1>
                    <p class="workspace-root" title=${workspace?.root ?? ""}>${workspace == null ? "loading…" : basename(workspace.root)}</p>
                </header>
                <section class="files">
                    <h2>Workspace</h2>
                    <ul class="tree">
                        ${workspace == null
                            ? null
                            : workspace.entries.map(
                                  (e) => html`<${FileEntry} key=${e.path} entry=${e} on_open_notebook=${open_notebook} depth=${0} />`
                              )}
                    </ul>
                </section>
                <section class="running">
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
            </aside>
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
