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

const FileEntry = ({ entry, on_open_notebook, on_open_file, on_create_in, on_delete, depth }) => {
    const [open, set_open] = useState(false)
    if (entry.type === "dir") {
        return html`<li class="dir ${open ? "open" : ""}">
            <div class="entry-row">
                <button class="entry" onClick=${() => set_open(!open)}><span class="icon chevron"></span>${entry.name}</button>
                <button class="row-action" title="New notebook or file in ${entry.name}/" onClick=${() => on_create_in(entry.path)}>+</button>
            </div>
            ${open
                ? html`<ul>
                      ${entry.children.map(
                          (c) =>
                              html`<${FileEntry}
                                  key=${c.path}
                                  entry=${c}
                                  on_open_notebook=${on_open_notebook}
                                  on_open_file=${on_open_file}
                                  on_create_in=${on_create_in}
                                  on_delete=${on_delete}
                                  depth=${depth + 1}
                              />`
                      )}
                  </ul>`
                : null}
        </li>`
    }
    const is_notebook = entry.type === "notebook"
    return html`<li class=${is_notebook ? "notebook" : "file"}>
        <div class="entry-row">
            <button
                class="entry ${is_notebook ? "" : "quiet"}"
                title=${entry.path}
                onClick=${() => (is_notebook ? on_open_notebook(entry.path) : on_open_file(entry.path))}
            >
                <span class="icon ${is_notebook ? "pluto-dot" : ""}"></span>${entry.name}
            </button>
            <button class="row-action danger" title="Delete ${entry.name}" onClick=${() => on_delete(entry)}>✕</button>
        </div>
    </li>`
}

/** The VS Code "Open Folder" experience: browse the server's filesystem, pick a folder.
 *  `open_workspace(path)` is provided by the parent (it handles confirmation + shutdown of
 *  running notebooks); `on_cancel` (optional) shows a back button when switching workspaces. */
const WorkspaceOpener = ({ open_workspace: open_workspace_raw, on_cancel }) => {
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
                await open_workspace_raw(path)
            } catch (e) {
                String(e).includes("cancelled") || set_error(String(e))
            }
        },
        [open_workspace_raw]
    )

    const recent = get_recent_workspaces()

    // "/Users/dale/dev" → [{name: "/", path: "/"}, {name: "Users", path: "/Users"}, …]
    const crumbs =
        listing == null
            ? []
            : [
                  { name: "/", path: "/" },
                  ...listing.path
                      .split("/")
                      .filter((s) => s !== "")
                      .map((name, i, parts) => ({ name, path: "/" + parts.slice(0, i + 1).join("/") })),
              ]

    return html`<div class="workspace-opener">
        <div class="bubble opener-card">
            <header>
                <img class="land-logo opener-logo" src="img/plutoland.svg" alt="PlutoLand" />
                <h1>Pluto<span class="land-accent">Land</span></h1>
                <p class="subtitle">Open a folder as your workspace — notebooks inside it open as tabs.</p>
                ${on_cancel == null ? null : html`<button class="opener-cancel" title="Back to the current workspace" onClick=${on_cancel}>← back</button>`}
            </header>

            ${recent.length > 0
                ? html`<section>
                      <h2>Recent</h2>
                      <div class="recent-grid">
                          ${recent.map(
                              (p) => html`<button class="recent-card" title=${p} onClick=${() => open_workspace(p)}>
                                  <span class="recent-icon">🗂</span>
                                  <span class="recent-name">${basename(p)}</span>
                                  <span class="recent-path">${p}</span>
                              </button>`
                          )}
                      </div>
                  </section>`
                : null}

            <section>
                <h2>Browse</h2>
                ${listing == null
                    ? html`<p class="subtitle">loading…</p>`
                    : html`
                          <nav class="breadcrumbs">
                              ${crumbs.map(
                                  (c, i) => html`<button
                                          class="crumb ${i === crumbs.length - 1 ? "current" : ""}"
                                          onClick=${() => browse(c.path)}
                                          title=${c.path}
                                      >
                                          ${c.name}</button
                                      >${i < crumbs.length - 1 && c.name !== "/" ? html`<span class="crumb-sep">/</span>` : null}`
                              )}
                          </nav>
                          <div class="dir-grid">
                              ${listing.dirs.map(
                                  (name) => html`<button class="dir-pill" title=${`${listing.path}/${name}`} onClick=${() => browse(`${listing.path}/${name}`)}>
                                      <span class="dir-icon">📁</span>${name}
                                  </button>`
                              )}
                              ${listing.dirs.length === 0 ? html`<p class="subtitle">no subfolders</p>` : null}
                          </div>
                          <div class="opener-actions">
                              <button class="open-this-folder" onClick=${() => open_workspace(listing.path)}>
                                  Open <strong>${basename(listing.path) || "/"}</strong> as workspace
                              </button>
                              <form
                                  class="paste-path"
                                  onSubmit=${(e) => {
                                      e.preventDefault()
                                      const v = e.target.elements.path.value.trim()
                                      if (v !== "") browse(v)
                                  }}
                              >
                                  <input name="path" type="text" placeholder="…or paste a folder path and press Enter" autocomplete="off" />
                              </form>
                          </div>
                      `}
            </section>
            ${error == null ? null : html`<p class="opener-error">${error}</p>`}
        </div>
    </div>`
}


/** The integrated terminal: xterm.js bridged to a real shell over the /terminal websocket.
 *  Wire protocol: we send "0:<keys>" and "1:<rows>,<cols>" text frames; the server sends raw
 *  PTY bytes as binary frames. The shell starts in the workspace folder. */
const TerminalPanel = ({ visible }) => {
    const node_ref = useRef(null)
    const started = useRef(false)

    useEffect(() => {
        if (!visible || started.current || node_ref.current == null) return
        started.current = true
        ;(async () => {
            const [{ Terminal }, { FitAddon }] = await Promise.all([
                import("https://esm.sh/@xterm/xterm@5.5.0?target=es2020"),
                import("https://esm.sh/@xterm/addon-fit@0.10.0?target=es2020"),
            ])
            const styles = getComputedStyle(document.documentElement)
            const term = new Terminal({
                fontSize: 13,
                fontFamily: "JuliaMono, SFMono-Regular, Menlo, Consolas, monospace",
                cursorBlink: true,
                theme: {
                    background: styles.getPropertyValue("--code-background").trim() || "#1f1f1f",
                    foreground: styles.getPropertyValue("--pluto-output-color").trim() || "#dddddd",
                },
            })
            const fit = new FitAddon()
            term.loadAddon(fit)
            term.open(node_ref.current)
            fit.fit()
            let tid = localStorage.getItem("plutoland terminal id")
            if (tid == null) {
                tid = Math.random().toString(36).slice(2, 12)
                localStorage.setItem("plutoland terminal id", tid)
            }
            const proto = window.location.protocol === "https:" ? "wss" : "ws"
            const socket = new WebSocket(`${proto}://${window.location.host}/terminal?tid=${tid}`)
            socket.binaryType = "arraybuffer"
            socket.onmessage = (e) => term.write(typeof e.data === "string" ? e.data : new Uint8Array(e.data))
            socket.onopen = () => socket.send(`1:${term.rows},${term.cols}`)
            socket.onclose = () => term.write("\r\n\x1b[2m[disconnected — the shell is still running; reload to reattach]\x1b[0m\r\n")
            term.onData((d) => socket.readyState === WebSocket.OPEN && socket.send("0:" + d))
            term.onResize(({ rows, cols }) => socket.readyState === WebSocket.OPEN && socket.send(`1:${rows},${cols}`))
            const ro = new ResizeObserver(() => {
                try {
                    fit.fit()
                } catch {}
            })
            ro.observe(node_ref.current)
        })()
    }, [visible])

    return html`<div class="terminal-host" ref=${node_ref}></div>`
}


// dirty state per open file, shared so close_tab can warn
const file_dirty = new Map()

/** A text-file editor pane built on Pluto's own bundled CodeMirror (imports/CodemirrorPlutoSetup.js),
 *  with syntax colors wired to Pluto's --cm-color-* theme variables. Save with the button or Ctrl/Cmd+S. */
const FileEditorPane = ({ path, visible }) => {
    const node_ref = useRef(null)
    const view_ref = useRef(null)
    const started = useRef(false)
    const [dirty, set_dirty] = useState(false)
    const [status, set_status] = useState("loading…")

    const save = useCallback(async () => {
        const view = view_ref.current
        if (view == null) return
        try {
            await get_json(`./api/v1/file/save?path=${encodeURIComponent(path)}`, { method: "POST", body: view.state.doc.toString() })
            file_dirty.set(path, false)
            set_dirty(false)
            set_status("saved")
            setTimeout(() => set_status(""), 1500)
        } catch (e) {
            set_status(String(e))
        }
    }, [path])

    useEffect(() => {
        if (!visible || started.current || node_ref.current == null) return
        started.current = true
        ;(async () => {
            try {
                const cm = await import("./imports/CodemirrorPlutoSetup.js")
                const content = await get_text(`./api/v1/file?path=${encodeURIComponent(path)}`)
                const v = (name) => getComputedStyle(document.documentElement).getPropertyValue(name).trim()
                const pluto_colors = cm.HighlightStyle.define(
                    [
                        { tag: cm.tags.keyword, color: "var(--cm-color-keyword)" },
                        { tag: cm.tags.comment, color: "var(--cm-color-comment)", fontStyle: "italic" },
                        { tag: cm.tags.string, color: "var(--cm-color-string)" },
                        { tag: cm.tags.number, color: "var(--cm-color-literal)" },
                        { tag: cm.tags.literal, color: "var(--cm-color-literal)" },
                        { tag: cm.tags.macroName, color: "var(--cm-color-macro)" },
                        { tag: cm.tags.variableName, color: "var(--cm-color-variable)" },
                        { tag: cm.tags.heading, color: "var(--cm-color-md)", fontWeight: "700" },
                        { tag: cm.tags.link, color: "var(--cm-color-link)" },
                    ],
                    { all: { color: "var(--cm-color-editor-text)" } }
                )
                const ext = path.split(".").pop()?.toLowerCase()
                const language =
                    ext === "jl"
                        ? [cm.julia()]
                        : ext === "md"
                          ? [cm.markdown()]
                          : ext === "toml"
                            ? (() => {
                                  try {
                                      return [cm.StreamLanguage.define(cm.toml)]
                                  } catch {
                                      return []
                                  }
                              })()
                            : ext === "css"
                              ? [cm.css()]
                              : ext === "js" || ext === "mjs"
                                ? [cm.javascript()]
                                : ext === "html"
                                  ? [cm.html()]
                                  : ext === "py"
                                    ? [cm.python()]
                                    : []
                const view = new cm.EditorView({
                    state: cm.EditorState.create({
                        doc: content,
                        extensions: [
                            cm.lineNumbers(),
                            cm.history(),
                            cm.drawSelection(),
                            cm.indentOnInput(),
                            cm.bracketMatching(),
                            cm.highlightActiveLine(),
                            cm.syntaxHighlighting(pluto_colors),
                            ...language,
                            cm.keymap.of([
                                { key: "Mod-s", run: () => (save(), true) },
                                ...cm.defaultKeymap,
                                ...cm.historyKeymap,
                            ]),
                            cm.EditorView.updateListener.of((update) => {
                                if (update.docChanged) {
                                    file_dirty.set(path, true)
                                    set_dirty(true)
                                }
                            }),
                            cm.EditorView.theme({}, { dark: window.matchMedia("(prefers-color-scheme: dark)").matches }),
                        ],
                    }),
                    parent: node_ref.current,
                })
                view_ref.current = view
                set_status("")
            } catch (e) {
                set_status(String(e))
            }
        })()
    }, [visible])

    return html`<div class="file-pane">
        <div class="file-toolbar">
            <span class="file-path" title=${path}>${path}</span>
            <span class="file-status">${dirty ? "●" : ""} ${status}</span>
            <button class="file-save ${dirty ? "dirty" : ""}" onClick=${save} title="Save (Ctrl/Cmd+S)">Save</button>
        </div>
        <div class="file-editor" ref=${node_ref}></div>
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
    const [terminal_open, set_terminal_open] = useState(() => localStorage.getItem("plutoland terminal open") === "true")
    const [terminal_height, set_terminal_height] = useState(() => Number(localStorage.getItem("plutoland terminal height")) || 280)
    const [terminal_width, set_terminal_width] = useState(() => Number(localStorage.getItem("plutoland terminal width")) || 420)
    const [terminal_dock, set_terminal_dock] = useState(() => (localStorage.getItem("plutoland terminal dock") === "right" ? "right" : "bottom"))
    const terminal_ever_opened = useRef(false)
    if (terminal_open) terminal_ever_opened.current = true
    const [show_opener, set_show_opener] = useState(false)
    const auto_tabbed = useRef(false)

    useEffect(() => {
        localStorage.setItem("plutoland sidebar width", String(sidebar_width))
        localStorage.setItem("plutoland sidebar hidden", String(sidebar_hidden))
        localStorage.setItem("plutoland terminal open", String(terminal_open))
        localStorage.setItem("plutoland terminal height", String(terminal_height))
        localStorage.setItem("plutoland terminal width", String(terminal_width))
        localStorage.setItem("plutoland terminal dock", terminal_dock)
    }, [sidebar_width, sidebar_hidden, terminal_open, terminal_height, terminal_width, terminal_dock])

    const start_terminal_resize = useCallback(
        (e) => {
            e.preventDefault()
            const vertical = terminal_dock === "bottom"
            document.body.classList.add(vertical ? "resizing-v" : "resizing")
            const move = (ev) =>
                vertical
                    ? set_terminal_height(Math.max(120, Math.min(window.innerHeight - 220, window.innerHeight - ev.clientY - 12)))
                    : set_terminal_width(Math.max(240, Math.min(window.innerWidth - 420, window.innerWidth - ev.clientX - 12)))
            const up = () => {
                document.body.classList.remove("resizing-v")
                document.body.classList.remove("resizing")
                window.removeEventListener("pointermove", move)
                window.removeEventListener("pointerup", up)
            }
            window.addEventListener("pointermove", move)
            window.addEventListener("pointerup", up)
        },
        [terminal_dock]
    )

    const add_tab = useCallback((id, path, kind = "notebook") => {
        set_tabs((tabs) => (tabs.some((t) => t.id === id) ? tabs : [...tabs, { id, path, kind }]))
        set_active(id)
    }, [])

    const open_file = useCallback(
        (path) => {
            add_tab(`file:${path}`, path, "file")
        },
        [add_tab]
    )

    const create_in = useCallback(
        async (dir) => {
            const name = prompt(`New file in ${dir.split("/").pop()}/ — a name ending in .jl becomes a Pluto notebook:`, "notebook.jl")
            if (name == null || name.trim() === "") return
            const path = `${dir}/${name.trim()}`
            try {
                if (name.trim().endsWith(".jl")) {
                    const id = await get_text("./new", { method: "POST" })
                    await get_text(`./move?id=${encodeURIComponent(id)}&newpath=${encodeURIComponent(path)}`, { method: "POST" })
                    add_tab(id, path)
                } else {
                    await get_json(`./api/v1/file/new?path=${encodeURIComponent(path)}`, { method: "POST" })
                    open_file(path)
                }
                refresh()
            } catch (e) {
                set_error(String(e))
            }
        },
        [add_tab, open_file, refresh]
    )

    const delete_entry = useCallback(
        async (entry) => {
            const what = entry.type === "notebook" ? "notebook (it will be shut down if running; its output cache is deleted too)" : "file"
            if (!confirm(`Delete ${entry.name}?\n\nThis permanently deletes the ${what}. There is no trash.`)) return
            try {
                await get_json(`./api/v1/file/delete?path=${encodeURIComponent(entry.path)}`, { method: "POST" })
                // close any tab showing it
                set_tabs((tabs) => tabs.filter((t) => t.path !== entry.path))
                file_dirty.delete(entry.path)
                refresh()
            } catch (e) {
                set_error(String(e))
            }
        },
        [refresh]
    )

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
        if (id.startsWith("file:")) {
            const path = id.slice(5)
            if (file_dirty.get(path) && !confirm("This file has unsaved changes. Close anyway?")) return
            file_dirty.delete(path)
        }
        // closing a notebook tab does NOT shut down the notebook (JupyterHub semantics) — it keeps running, listed under "Running"
        set_tabs((tabs) => {
            const remaining = tabs.filter((t) => t.id !== id)
            set_active((a) => (a === id ? (remaining.length > 0 ? remaining[remaining.length - 1].id : null) : a))
            return remaining
        })
    }, [])

    const switch_workspace = useCallback(
        async (path) => {
            if (running.length > 0) {
                const noun = running.length === 1 ? "1 running notebook" : `${running.length} running notebooks`
                const ok = confirm(
                    `Open a different workspace?\n\nThis will shut down ${noun}. Notebook files stay on disk, and outputs are cached in their .pluto-cache.toml sidecars — reopening them later restores everything.`
                )
                if (!ok) throw new Error("cancelled")
                for (const nb of running) {
                    await get_text(`./shutdown?id=${encodeURIComponent(nb.notebook_id)}`, { method: "POST" }).catch(() => {})
                }
                set_tabs([])
                set_active(null)
            }
            const result = await get_json(`./api/v1/workspace/open?path=${encodeURIComponent(path)}`, { method: "POST" })
            remember_workspace(result.root)
            set_show_opener(false)
            await refresh()
        },
        [running, refresh]
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

    // the opener shows on first load (no workspace yet) and on demand (switching workspaces)
    if (no_workspace || show_opener) {
        return html`<${WorkspaceOpener}
            open_workspace=${switch_workspace}
            on_cancel=${no_workspace ? null : () => set_show_opener(false)}
        />`
    }

    return html`
        <div id="land">
            ${sidebar_hidden
                ? html`<button id="sidebar-reopen" title="Show sidebar" onClick=${() => set_sidebar_hidden(false)}>☰</button>`
                : html`<aside style=${`width: ${sidebar_width}px`}>
                <header class="bubble">
                    <div class="header-row">
                        <img class="land-logo" src="img/plutoland.svg" alt="PlutoLand" />
                        <div class="header-text">
                            <h1>Pluto<span class="land-accent">Land</span></h1>
                            <p class="workspace-root" title=${workspace?.root ?? ""}>${workspace == null ? "loading…" : basename(workspace.root)}</p>
                        </div>
                        <div class="header-buttons">
                            <button class="header-button" title="Open a different folder as workspace" onClick=${() => set_show_opener(true)}>🗂</button>
                            <button class="header-button" title="Hide sidebar" onClick=${() => set_sidebar_hidden(true)}>⟨</button>
                        </div>
                    </div>
                </header>
                <section class="files bubble">
                    <h2>
                        Workspace
                        ${workspace == null
                            ? null
                            : html`<button class="row-action h2-action" title="New notebook or file in the workspace root" onClick=${() => create_in(workspace.root)}>+</button>`}
                    </h2>
                    <ul class="tree">
                        ${workspace == null
                            ? null
                            : workspace.entries.map(
                                  (e) =>
                                      html`<${FileEntry}
                                          key=${e.path}
                                          entry=${e}
                                          on_open_notebook=${open_notebook}
                                          on_open_file=${open_file}
                                          on_create_in=${create_in}
                                          on_delete=${delete_entry}
                                          depth=${0}
                                      />`
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
                <div class="main-split ${terminal_dock}">
                    <div class="editor-card">
                        <nav id="tabs">
                            <div class="tab-scroller">
                                ${tabs.map(
                                    (t) => html`<div class="tab ${t.id === active ? "active" : ""}" key=${t.id}>
                                        <button class="title" title=${t.path} onClick=${() => set_active(t.id)}>${basename(t.path)}</button>
                                        <button class="close" title="Close tab (notebook keeps running)" onClick=${() => close_tab(t.id)}>×</button>
                                    </div>`
                                )}
                            </div>
                            <button class="terminal-toggle ${terminal_open ? "active" : ""}" title="Toggle the integrated terminal (runs in the workspace folder)" onClick=${() =>
        set_terminal_open(!terminal_open)}>⌨ Terminal</button>
                            ${terminal_open
                                ? html`<button
                                      class="terminal-toggle dock-toggle"
                                      title=${terminal_dock === "bottom" ? "Dock terminal to the right" : "Dock terminal to the bottom"}
                                      onClick=${() => set_terminal_dock(terminal_dock === "bottom" ? "right" : "bottom")}
                                  >
                                      ${terminal_dock === "bottom" ? "◨" : "⬓"}
                                  </button>`
                                : null}
                        </nav>
                        <div id="frames">
                            ${tabs.map((t) =>
                                t.kind === "file"
                                    ? html`<div key=${t.id} class="pane ${t.id === active ? "active" : ""}">
                                          <${FileEditorPane} path=${t.path} visible=${t.id === active} />
                                      </div>`
                                    : // every notebook tab is the stock Pluto editor; iframes stay mounted so switching tabs never loses state
                                      html`<iframe key=${t.id} src=${`./edit?id=${t.id}`} class=${t.id === active ? "active" : ""}></iframe>`
                            )}
                            ${tabs.length === 0
                                ? html`<div class="empty-state">
                                      <p>Open a notebook from the workspace on the left, or create a new one.</p>
                                      <p class="hint">Agents can work here too: edit any notebook file, or use <code>pluto-collab</code>.</p>
                                  </div>`
                                : null}
                        </div>
                    </div>
                    ${terminal_ever_opened.current
                        ? html`
                              <div id="terminal-resizer" style=${terminal_open ? "" : "display: none"} onPointerDown=${start_terminal_resize}></div>
                              <div
                                  id="terminal-panel"
                                  class="bubble"
                                  style=${terminal_open
                                      ? terminal_dock === "bottom"
                                          ? `height: ${terminal_height}px`
                                          : `width: ${terminal_width}px`
                                      : "display: none"}
                              >
                                  <${TerminalPanel} visible=${terminal_open} />
                              </div>
                          `
                        : null}
                </div>
            </main>
            ${error == null ? null : html`<div id="land-error">${error}</div>`}
        </div>
    `
}

render(html`<${Land} />`, document.querySelector("#land-app"))
