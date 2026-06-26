// PlutoSpace — the workspace hub: a file browser + tabbed notebooks, all running on a
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

// One canonical homebase: the launcher tab names itself this, so a workspace's "home" button can focus it
// (or reopen it if it was closed) via window.open(url, HOMEBASE_WINDOW_NAME) — instead of every workspace
// spawning its own disconnected in-tab launcher.
const HOMEBASE_WINDOW_NAME = "plutospace-homebase"
const homebase_self_url = () => window.location.origin + window.location.pathname + window.location.search
// Tag a workspace URL with this homebase's address (in the #fragment — never sent to the server) so the
// workspace it opens knows where "home" is.
const with_homebase = (url) => (url == null ? url : `${url}#homebase=${encodeURIComponent(homebase_self_url())}`)

// `new URL(..., import.meta.url)` works unbundled in the browser AND gets rewritten by
// the bundler — a string src would 404 in frontend-dist where filenames are hashed.
const logo_url = new URL("img/plutospace.svg", import.meta.url).href

const RECENT_KEY = "plutospace recent workspaces"
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

// Terminals live in the terminal panel as their own tabs. Their shells persist on the server
// (keyed by tid), so we remember each terminal's tid + label and reattach on reload.
const TERMINALS_KEY = "plutospace terminals"
const restore_terminals = () => {
    try {
        const saved = JSON.parse(localStorage.getItem(TERMINALS_KEY) ?? "[]")
        if (!Array.isArray(saved)) return []
        return saved.filter((t) => t && typeof t.tid === "string").map((t) => ({ tid: t.tid, label: t.label ?? "Terminal" }))
    } catch {
        return []
    }
}

// How long to wait for an SSH connection before giving up (seconds). A busy ProxyJump login node can
// need well over the old 8s default just to relay the compute node's banner — so this is user-tunable
// from homebase. Mirrors the server's clamp (see SSH_CONNECT_TIMEOUT in CollabRemote.jl).
const SSH_TIMEOUT_KEY = "plutospace ssh connect timeout"
const SSH_TIMEOUT_DEFAULT = 25
const clamp_ssh_timeout = (v) => Math.max(3, Math.min(180, Math.round(Number(v) || SSH_TIMEOUT_DEFAULT)))
const get_ssh_timeout = () => {
    const v = Number(localStorage.getItem(SSH_TIMEOUT_KEY))
    return Number.isFinite(v) && v >= 3 ? clamp_ssh_timeout(v) : SSH_TIMEOUT_DEFAULT
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

/** Homebase: the VS Code "Open Folder" experience (browse the filesystem, pick a folder) plus a live
 *  list of every running workspace — local children AND SSH remotes — to reattach to or shut down.
 *  Picking a folder spawns a child server in a new tab (see connect_local); this view never leaves.
 *  `on_cancel` (optional) shows a back button when opened on top of an existing workspace. */
const WorkspaceOpener = ({ on_cancel, tunneled }) => {
    const [listing, set_listing] = useState(/** @type {{path: String, parent: String, dirs: Array<String>}?} */ (null))
    const [error, set_error] = useState(/** @type {String?} */ (null))
    const [ssh_hosts, set_ssh_hosts] = useState(/** @type {Array<String>} */ ([]))
    const [ssh_timeout, set_ssh_timeout] = useState(get_ssh_timeout)
    const [remote_states, set_remote_states] = useState(/** @type {Record<String, {state: String, detail: String, url: String?}>} */ ({}))
    // Picking a LOCAL folder spawns a child PlutoSpace server (its own process + tab), exactly like an
    // SSH remote — so this opener is "homebase": it never leaves to become a workspace, it launches them.
    const [local_states, set_local_states] = useState(/** @type {Record<String, {state: String, detail: String, url: String?}>} */ ({}))
    const [running, set_running] = useState(
        /** @type {Array<{kind: String, key: String, name: String, sub: String, state: String, url: String?, path?: String, host?: String}>} */ ([])
    )
    // a connect can be cancelled mid-flight: the poll loops below bail when their key lands in these sets
    const cancelled_hosts = useRef(/** @type {Set<String>} */ (new Set()))
    const cancelled_paths = useRef(/** @type {Set<String>} */ (new Set()))

    useEffect(() => {
        get_json("./api/v1/ssh_hosts")
            .then(set_ssh_hosts)
            .catch(() => {})
    }, [])

    // The SSH connect timeout is a homebase setting. The server resets it to its default on restart, so
    // push our stored value on load and whenever it changes (and persist it locally for next time).
    useEffect(() => {
        localStorage.setItem(SSH_TIMEOUT_KEY, String(ssh_timeout))
        fetch(`./api/v1/remote/config?connect_timeout=${encodeURIComponent(ssh_timeout)}`, { method: "POST" }).catch(() => {})
    }, [ssh_timeout])

    const connect_remote = useCallback(async (host) => {
        // everything happens server-side, idempotently: reuse a live tunnel/server, bootstrap only on first contact
        cancelled_hosts.current.delete(host) // a fresh attempt clears any earlier cancel
        try {
            let status = await get_json(`./api/v1/remote/open?host=${encodeURIComponent(host)}`, { method: "POST" })
            set_remote_states((s) => ({ ...s, [host]: status }))
            while (status.state !== "ready" && status.state !== "error") {
                await new Promise((r) => setTimeout(r, 1500))
                if (cancelled_hosts.current.has(host)) return // cancelled: stop polling (cancel_remote cleared the UI)
                status = await get_json(`./api/v1/remote/status?host=${encodeURIComponent(host)}`)
                set_remote_states((s) => ({ ...s, [host]: status }))
            }
            if (status.state === "ready" && status.url != null) {
                window.open(with_homebase(status.url), "_blank") // may be blocked: the pill stays a clickable link either way
            }
        } catch (e) {
            if (cancelled_hosts.current.has(host)) return
            set_remote_states((s) => ({ ...s, [host]: { state: "error", detail: String(e), url: null } }))
        }
    }, [])

    // Cancel / dismiss / disconnect a remote: stop polling, tell the server to bail + drop it, clear the UI.
    const cancel_remote = useCallback(async (host) => {
        cancelled_hosts.current.add(host)
        try {
            await fetch(`./api/v1/remote/cancel?host=${encodeURIComponent(host)}`, { method: "POST" })
        } catch (e) {}
        set_remote_states((s) => {
            const c = { ...s }
            delete c[host]
            return c
        })
        set_running((rs) => rs.filter((w) => !(w.kind === "remote" && w.host === host)))
    }, [])

    // Local twin of connect_remote: spawn (or reattach to) the child server for this folder, then open it
    // in a new tab. The homebase tab stays put, so you can launch as many workspaces as you like.
    const connect_local = useCallback(async (path) => {
        cancelled_paths.current.delete(path) // a fresh attempt clears any earlier cancel
        try {
            let status = await get_json(`./api/v1/local/open?path=${encodeURIComponent(path)}`, { method: "POST" })
            set_local_states((s) => ({ ...s, [path]: status }))
            while (status.state !== "ready" && status.state !== "error") {
                await new Promise((r) => setTimeout(r, 1000))
                if (cancelled_paths.current.has(path)) return // cancelled: stop polling
                status = await get_json(`./api/v1/local/status?path=${encodeURIComponent(path)}`)
                set_local_states((s) => ({ ...s, [path]: status }))
            }
            if (status.state === "ready" && status.url != null) {
                remember_workspace(path)
                window.open(with_homebase(status.url), "_blank") // may be blocked: the ready card stays a clickable link either way
            }
        } catch (e) {
            if (cancelled_paths.current.has(path)) return
            set_local_states((s) => ({ ...s, [path]: { state: "error", detail: String(e), url: null } }))
        }
    }, [])

    // Cancel an in-flight (or errored) local spawn — no confirm, nothing's running yet. (Shutting down a
    // READY workspace, which has live notebooks, goes through shutdown_local with its confirm instead.)
    const cancel_local = useCallback(async (path) => {
        cancelled_paths.current.add(path)
        try {
            await fetch(`./api/v1/local/shutdown?path=${encodeURIComponent(path)}`, { method: "POST" })
        } catch (e) {}
        set_local_states((s) => {
            const c = { ...s }
            delete c[path]
            return c
        })
        set_running((rs) => rs.filter((w) => !(w.kind === "local" && w.path === path)))
    }, [])

    const shutdown_local = useCallback(async (path) => {
        if (
            !window.confirm(
                `Shut down the workspace server for ${basename(path)}?\n\nIts running notebooks will stop. Files stay on disk and outputs are cached in their .pluto-cache.toml sidecars, so reopening restores everything.`
            )
        )
            return
        try {
            await fetch(`./api/v1/local/shutdown?path=${encodeURIComponent(path)}`, { method: "POST" })
        } catch (e) {}
        set_local_states((s) => {
            const c = { ...s }
            delete c[path]
            return c
        })
        set_running((rs) => rs.filter((w) => !(w.kind === "local" && w.path === path)))
    }, [])

    // Open a folder as a workspace. Local: spawn a child server in its own tab (connect_local). Over a
    // tunnel (a remote server): switch THIS server's workspace in-place and reload — the child's port
    // wouldn't be reachable from the browser, so a new tab would just fail to connect.
    const open_workspace = useCallback(
        async (path) => {
            if (!tunneled) return connect_local(path)
            try {
                await get_json(`./api/v1/workspace/open?path=${encodeURIComponent(path)}`, { method: "POST" })
                remember_workspace(path)
                window.location.reload()
            } catch (e) {
                set_error(String(e))
            }
        },
        [tunneled, connect_local]
    )

    // The ✕ on a Running Workspace card: cancel a connecting one, dismiss an errored one, disconnect a
    // ready remote, or shut down a ready local workspace (that one confirms — it has live notebooks).
    const dismiss_running = useCallback(
        (w) => {
            if (w.kind === "remote") return cancel_remote(w.host)
            if (w.state === "ready") return shutdown_local(w.path)
            return cancel_local(w.path)
        },
        [cancel_remote, shutdown_local, cancel_local]
    )

    // Homebase poll: every running workspace — local children AND SSH remotes — in one place, so you can
    // see them all and reattach in a click. (Best-effort; the lists just don't render if a fetch fails.)
    useEffect(() => {
        let alive = true
        const load = async () => {
            const [locals, remotes] = await Promise.all([
                get_json("./api/v1/local/list").catch(() => []),
                get_json("./api/v1/remote/list").catch(() => []),
            ])
            if (!alive) return
            set_running([
                ...locals.map((w) => ({ kind: "local", key: `local:${w.path}`, name: basename(w.path) || w.path, sub: w.path, state: w.state, url: w.url, path: w.path })),
                ...remotes.map((r) => ({ kind: "remote", key: `remote:${r.host}`, name: r.host, sub: "SSH remote", state: r.state, url: r.url, host: r.host })),
            ])
        }
        load()
        const iv = setInterval(load, 3000)
        return () => {
            alive = false
            clearInterval(iv)
        }
    }, [])

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
                <img class="land-logo opener-logo" src=${logo_url} alt="PlutoSpace" />
                <h1>Pluto<span class="land-accent">Space</span></h1>
                <p class="subtitle">Open a folder as your workspace — notebooks inside it open as tabs.</p>
                ${on_cancel == null ? null : html`<button class="opener-cancel" title="Close — back to your workspace" onClick=${on_cancel}><span class="opener-cancel-icon"></span></button>`}
            </header>

            ${!tunneled && running.length > 0
                ? html`<section>
                      <h2>Running Workspaces</h2>
                      <div class="recent-grid">
                          ${running.map(
                              (w) => html`<div class="recent-card running-card ${w.state === "ready" ? "" : "running-busy"}" key=${w.key}>
                                  ${w.url != null
                                      ? html`<a class="running-open" href=${with_homebase(w.url)} target="_blank" rel="opener" title=${`Open ${w.name}`}>
                                            <span class="recent-icon">${w.kind === "remote" ? "🛰" : "🗂"}</span>
                                            <span class="recent-name">${w.name}</span>
                                            <span class="recent-path">${w.sub}</span>
                                        </a>`
                                      : html`<div class="running-open is-busy">
                                            <span class="recent-icon">${w.kind === "remote" ? "🛰" : "🗂"}</span>
                                            <span class="recent-name">${w.name}</span>
                                            <span class="recent-path">${w.state}…</span>
                                        </div>`}
                                  <button
                                      class="running-shutdown"
                                      title=${w.state === "error" ? "Dismiss" : w.state !== "ready" ? "Cancel" : w.kind === "remote" ? "Disconnect" : "Shut down this workspace"}
                                      onClick=${() => dismiss_running(w)}
                                  >
                                      ✕
                                  </button>
                              </div>`
                          )}
                      </div>
                  </section>`
                : null}

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
            ${!tunneled && ssh_hosts.length > 0
                ? html`<section>
                      <h2>SSH Remotes</h2>
                      <p class="subtitle small">
                          Click a host: the whole Land (files, kernels, terminal) runs on that machine over an SSH tunnel. First contact installs the
                          server there; after that it reconnects instantly.
                      </p>
                      <label
                          class="ssh-timeout"
                          title="How long to wait for an SSH connection — including the banner from a slow ProxyJump login node — before giving up."
                      >
                          Connection timeout
                          <input
                              type="number"
                              min="3"
                              max="180"
                              step="1"
                              value=${ssh_timeout}
                              onChange=${(e) => set_ssh_timeout(clamp_ssh_timeout(e.target.value))}
                          />
                          <span class="unit">s</span>
                          <span class="ssh-timeout-hint">Raise this if a host fails with “timed out reaching … slow SSH hop”.</span>
                      </label>
                      <div class="dir-grid">
                          ${ssh_hosts.map((h) => {
                              const st = remote_states[h]
                              const busy = st != null && st.state !== "ready" && st.state !== "error"
                              return st?.state === "ready" && st.url != null
                                  ? html`<a class="dir-pill remote-ready" href=${with_homebase(st.url)} target="_blank" rel="opener" title=${st.detail}>
                                        <span class="dir-icon">🛰</span>${h} →
                                    </a>`
                                  : html`<button
                                        class="dir-pill ${busy ? "remote-busy" : ""} ${st?.state === "error" ? "remote-error" : ""}"
                                        title=${st?.detail ?? `Open a workspace on ${h}`}
                                        onClick=${() => connect_remote(h)}
                                    >
                                        <span class="dir-icon">🛰</span>${busy ? `${h}: ${st.state}…` : st?.state === "error" ? `${h}: failed (retry)` : h}
                                    </button>`
                          })}
                      </div>
                      ${Object.entries(remote_states)
                          .filter(([_, st]) => st.state !== "ready" && st.state !== "error")
                          .map(
                              ([h, st]) => html`<div class="remote-progress" key=${h}>
                                  <span class="remote-spinner"></span>
                                  <div class="remote-progress-text">
                                      <strong>Connecting to ${h} — ${st.state}</strong>
                                      <span>${st.detail}</span>
                                      ${st.state === "installing"
                                          ? html`<span class="remote-progress-note">First-time setup compiles a lot of Julia — this is the slow step. Leave this page open; it will connect by itself.</span>`
                                          : null}
                                  </div>
                                  <button class="remote-cancel" title="Cancel this connection" onClick=${() => cancel_remote(h)}>Cancel</button>
                              </div>`
                          )}
                      ${Object.values(remote_states).some((st) => st.state === "error")
                          ? html`<p class="opener-error">${Object.entries(remote_states).filter(([_, st]) => st.state === "error").map(([h, st]) => `${h}: ${st.detail}`).join(" · ")}</p>`
                          : null}
                  </section>`
                : null}
            ${Object.entries(local_states)
                .filter(([_, st]) => st.state !== "ready" && st.state !== "error")
                .map(
                    ([path, st]) => html`<div class="remote-progress" key=${path}>
                        <span class="remote-spinner"></span>
                        <div class="remote-progress-text">
                            <strong>Starting ${basename(path)} — ${st.state}</strong>
                            <span>${st.detail}</span>
                        </div>
                        <button class="remote-cancel" title="Cancel this launch" onClick=${() => cancel_local(path)}>Cancel</button>
                    </div>`
                )}
            ${Object.values(local_states).some((st) => st.state === "error")
                ? html`<p class="opener-error">
                      ${Object.entries(local_states)
                          .filter(([_, st]) => st.state === "error")
                          .map(([path, st]) => `${basename(path)}: ${st.detail}`)
                          .join(" · ")}
                  </p>`
                : null}
            ${error == null ? null : html`<p class="opener-error">${error}</p>`}
        </div>
    </div>`
}


/** A terminal view: xterm.js bridged to a real shell over the /terminal websocket, keyed by `tid`.
 *  Wire protocol: we send "0:<keys>" and "1:<rows>,<cols>" text frames; the server sends raw PTY
 *  bytes as binary frames. The shell starts in the workspace folder and PERSISTS on the server by
 *  `tid` — so reattaching (a tab switch, a reload) replays scrollback. Used by both the docked
 *  terminal and each terminal tab; the only difference is which `tid` they own. */
const TerminalView = ({ tid, cwd, visible }) => {
    const node_ref = useRef(null)
    const started = useRef(false)
    const fit_ref = useRef(null)
    const refit_timer = useRef(null)

    // Fit ONLY when the host is genuinely on-screen at a real size, and debounced so a panel that
    // is animating open settles before we measure. Fitting a hidden tab (display:none → 0px) makes
    // xterm clamp to its minimum 2 columns and ship that to the PTY — which is exactly what leaves a
    // backgrounded terminal reattaching wrapped to a sliver. The guard makes a hide a no-op.
    const refit = useCallback(() => {
        clearTimeout(refit_timer.current)
        refit_timer.current = setTimeout(() => {
            const node = node_ref.current
            const fit = fit_ref.current
            if (node == null || fit == null) return
            if (node.offsetParent === null || node.clientWidth < 24 || node.clientHeight < 24) return
            try {
                fit.fit()
            } catch {}
        }, 120)
    }, [])

    useEffect(() => {
        if (!visible) return
        // returning to this tab (or first reveal of an already-started one): re-measure once painted
        if (started.current) {
            refit()
            return
        }
        if (node_ref.current == null) return
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
                scrollback: 5000,
                theme: {
                    // the terminal interior stays dark in both themes (see --terminal-bg/fg in themes/*.css)
                    background: styles.getPropertyValue("--terminal-bg").trim() || "#1f1f1f",
                    foreground: styles.getPropertyValue("--terminal-fg").trim() || "#dddddd",
                },
            })
            const fit = new FitAddon()
            term.loadAddon(fit)
            fit_ref.current = fit
            term.open(node_ref.current)

            // Assigned when the websocket opens (below); the paste handler needs it, so it lives out here.
            let socket = null

            // Paste from the clipboard. An image can't go through xterm's text-only paste — the bytes have
            // to reach wherever the shell runs (local, or the remote over SSH). So read the clipboard
            // richly: if it holds an image, base64 it and send a "2:<ext>:<base64>" frame — the server
            // drops it in a temp file and types the path, so any CLI agent in the shell can open it.
            // Otherwise paste text, exactly as before. Falls back to readText() if read() is unavailable.
            const paste_from_clipboard = async () => {
                try {
                    if (navigator.clipboard?.read) {
                        const items = await navigator.clipboard.read()
                        for (const item of items) {
                            const image_type = item.types.find((ty) => ty.startsWith("image/"))
                            if (image_type == null) continue
                            const bytes = new Uint8Array(await (await item.getType(image_type)).arrayBuffer())
                            let bin = ""
                            for (let i = 0; i < bytes.length; i += 0x8000) {
                                bin += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000))
                            }
                            const ext = image_type.split("/")[1] || "png"
                            if (socket?.readyState === WebSocket.OPEN) socket.send(`2:${ext}:${btoa(bin)}`)
                            return
                        }
                    }
                } catch {
                    // read() can be unavailable or blocked (permissions/focus) — fall through to text
                }
                try {
                    const text = await navigator.clipboard?.readText()
                    if (text) term.paste(text)
                } catch {}
            }

            // Copy/paste: Cmd/Ctrl+C copies when there is a selection (otherwise it falls through to the
            // shell as SIGINT); Cmd+V — and Ctrl+Shift+V — paste from the clipboard (text or image). (xterm
            // already forwards a native browser paste to the shell; this adds the explicit shortcuts, the
            // selection-aware copy that xterm does not do on its own, and image paste.)
            term.attachCustomKeyEventHandler((e) => {
                if (e.type !== "keydown") return true
                if ((e.metaKey || e.ctrlKey) && (e.key === "c" || e.key === "C") && term.hasSelection()) {
                    navigator.clipboard?.writeText(term.getSelection()).catch(() => {})
                    return false
                }
                if ((e.metaKey && e.key === "v") || (e.ctrlKey && e.shiftKey && (e.key === "v" || e.key === "V"))) {
                    paste_from_clipboard()
                    return false
                }
                return true
            })

            // Measure after the webfont is ready, so the cell size (hence the column count) is correct.
            try {
                await document.fonts?.ready
            } catch {}
            refit()

            const proto = window.location.protocol === "https:" ? "wss" : "ws"
            // Open the shell in the workspace the client is showing (local or ssh-remote), not wherever
            // the server happened to launch. The server falls back to its workspace_folder if omitted.
            const cwd_param = cwd ? `&cwd=${encodeURIComponent(cwd)}` : ""
            socket = new WebSocket(`${proto}://${window.location.host}/terminal?tid=${tid}${cwd_param}`)
            socket.binaryType = "arraybuffer"
            socket.onmessage = (e) => term.write(typeof e.data === "string" ? e.data : new Uint8Array(e.data))
            socket.onopen = () => {
                refit()
                socket.send(`1:${term.rows},${term.cols}`)
            }
            socket.onclose = () => term.write("\r\n\x1b[2m[disconnected — the shell is still running; reload to reattach]\x1b[0m\r\n")
            term.onData((d) => socket.readyState === WebSocket.OPEN && socket.send("0:" + d))
            term.onResize(({ rows, cols }) => socket.readyState === WebSocket.OPEN && socket.send(`1:${rows},${cols}`))
            const ro = new ResizeObserver(() => refit())
            ro.observe(node_ref.current)
        })()
    }, [visible, refit])

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
    const [tabs, set_tabs] = useState(/** @type {Array<{id: String, path: String, kind?: String}>} */ ([]))
    const [active, set_active] = useState(/** @type {String?} */ (null))
    const [error, set_error] = useState(/** @type {String?} */ (null))
    const [sidebar_width, set_sidebar_width] = useState(() => Number(localStorage.getItem("plutospace sidebar width")) || 290)
    const [sidebar_hidden, set_sidebar_hidden] = useState(() => localStorage.getItem("plutospace sidebar hidden") === "true")
    const [terminal_open, set_terminal_open] = useState(() => localStorage.getItem("plutospace terminal open") === "true")
    const [terminal_height, set_terminal_height] = useState(() => Number(localStorage.getItem("plutospace terminal height")) || 280)
    const [terminal_width, set_terminal_width] = useState(() => Number(localStorage.getItem("plutospace terminal width")) || 420)
    const [terminal_dock, set_terminal_dock] = useState(() => (localStorage.getItem("plutospace terminal dock") === "right" ? "right" : "bottom"))
    const terminal_ever_opened = useRef(false)
    if (terminal_open) terminal_ever_opened.current = true
    const [show_opener, set_show_opener] = useState(false)
    const [menu_open, set_menu_open] = useState(false)
    const menu_ref = useRef(null)
    // Close the header overflow menu on an outside click or Escape — standard popover behaviour.
    useEffect(() => {
        if (!menu_open) return
        const on_pointer = (e) => {
            if (menu_ref.current != null && !menu_ref.current.contains(e.target)) set_menu_open(false)
        }
        const on_key = (e) => {
            if (e.key === "Escape") set_menu_open(false)
        }
        document.addEventListener("pointerdown", on_pointer)
        document.addEventListener("keydown", on_key)
        return () => {
            document.removeEventListener("pointerdown", on_pointer)
            document.removeEventListener("keydown", on_key)
        }
    }, [menu_open])
    const auto_tabbed = useRef(false)
    // If this tab was spawned by a homebase, it carries the homebase URL in its #fragment — remember it so
    // the "home" button returns there instead of opening a disconnected in-tab launcher.
    const homebase_url = useRef(/** @type {String?} */ (null))
    if (homebase_url.current == null) {
        const m = window.location.hash.match(/[#&]homebase=([^&]+)/)
        if (m) {
            try {
                homebase_url.current = decodeURIComponent(m[1])
            } catch (e) {}
        }
    }
    // This server may be reached over an SSH tunnel (when it's a remote workspace). If so, its child
    // workspace ports aren't forwarded to the browser, so workspaces open IN-PLACE rather than in new tabs.
    const [tunneled, set_tunneled] = useState(false)
    useEffect(() => {
        get_json("./api/v1/config")
            .then((c) => set_tunneled(!!(c && c.tunneled)))
            .catch(() => {})
    }, [])

    // The launcher (no workspace of its own) is THE homebase — name the tab so workspaces can target it.
    useEffect(() => {
        if (no_workspace) window.name = HOMEBASE_WINDOW_NAME
    }, [no_workspace])

    // Tab title tells the homebase apart from workspaces in the browser's tab strip: the launcher reads
    // "PlutoSpace (launcher)"; a workspace reads "PlutoSpace — <folder>".
    useEffect(() => {
        document.title = no_workspace ? "PlutoSpace (launcher)" : workspace?.root ? `PlutoSpace — ${basename(workspace.root)}` : "PlutoSpace"
    }, [no_workspace, workspace])

    // "Home" from inside a workspace. Over a tunnel: clear the workspace and reload this same tab (the
    // remote homebase). Otherwise: focus the homebase tab if open, or reopen it if it was closed — one
    // shared homebase, never a disconnected duplicate. (In-tab opener only when no homebase is known.)
    const go_home = useCallback(() => {
        if (tunneled) {
            fetch("./api/v1/workspace/close", { method: "POST" }).finally(() => window.location.reload())
            return
        }
        // Focus the homebase tab that opened us. opener.focus() is one of the few cross-origin-permitted
        // calls, so unlike window.open(url, name) it actually focuses across the different ports our
        // workspaces live on — and it doesn't reload the homebase. (Anchor-opened tabs keep their opener
        // thanks to rel="opener" on the workspace links.)
        try {
            if (window.opener && !window.opener.closed) {
                window.opener.focus()
                return
            }
        } catch (e) {}
        // No live opener. If we know the homebase, switch to its tab: reuse it (never a duplicate) and
        // focus the returned handle, so an ALREADY-OPEN homebase actually gets raised to the front — plain
        // window.open(url, name) reuses the tab but only auto-focuses when it has to CREATE one.
        if (homebase_url.current) {
            // window.open("", name) hands back the existing named tab WITHOUT reloading it; if none is open
            // it returns a fresh blank tab, which we then point at the homebase.
            let w = null
            try {
                w = window.open("", HOMEBASE_WINDOW_NAME)
            } catch (e) {}
            if (w == null) {
                // Popup blocked / unsupported: last-resort reopen-by-name.
                window.open(homebase_url.current, HOMEBASE_WINDOW_NAME)
                return
            }
            let is_blank = false
            try {
                is_blank = w.location.href === "about:blank"
            } catch (e) {
                // cross-origin: the homebase runs on another port, so it's already open — just focus it.
            }
            if (is_blank) {
                try {
                    w.location.href = homebase_url.current
                } catch (e) {}
            }
            try {
                w.focus()
            } catch (e) {}
            return
        }
        set_show_opener(true)
    }, [tunneled])

    // Terminals are tabs INSIDE the terminal panel (like VS Code). Each is a persistent shell
    // keyed by tid; the list + active terminal are restored on reload. `terminal_seq` numbers them.
    const [terminals, set_terminals] = useState(/** @type {Array<{tid: String, label: String}>} */ (() => restore_terminals()))
    const [active_terminal, set_active_terminal] = useState(
        /** @type {String?} */ (() => {
            const r = restore_terminals()
            return r.length ? r[r.length - 1].tid : null
        })
    )
    const terminal_seq = useRef(/** @type {Number} */ (-1))
    if (terminal_seq.current < 0) {
        const nums = terminals.map((t) => parseInt(String(t.label ?? "").replace(/[^0-9]/g, ""), 10)).filter((x) => !isNaN(x))
        terminal_seq.current = nums.length ? Math.max(...nums) : 0
    }

    useEffect(() => {
        localStorage.setItem("plutospace sidebar width", String(sidebar_width))
        localStorage.setItem("plutospace sidebar hidden", String(sidebar_hidden))
        localStorage.setItem("plutospace terminal open", String(terminal_open))
        localStorage.setItem("plutospace terminal height", String(terminal_height))
        localStorage.setItem("plutospace terminal width", String(terminal_width))
        localStorage.setItem("plutospace terminal dock", terminal_dock)
    }, [sidebar_width, sidebar_hidden, terminal_open, terminal_height, terminal_width, terminal_dock])

    useEffect(() => {
        localStorage.setItem(TERMINALS_KEY, JSON.stringify(terminals.map((t) => ({ tid: t.tid, label: t.label }))))
    }, [terminals])

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

    const new_terminal = useCallback(() => {
        terminal_seq.current += 1
        const tid = "term-" + Math.random().toString(36).slice(2, 12)
        set_terminals((ts) => [...ts, { tid, label: `Terminal ${terminal_seq.current}` }])
        set_active_terminal(tid)
        set_terminal_open(true)
    }, [])

    const close_terminal = useCallback((tid) => {
        set_terminals((ts) => {
            const remaining = ts.filter((t) => t.tid !== tid)
            set_active_terminal((a) => (a === tid ? (remaining.length ? remaining[remaining.length - 1].tid : null) : a))
            return remaining
        })
    }, [])

    // opening the terminal panel with no terminals yet spins up the first one
    useEffect(() => {
        if (terminal_open && terminals.length === 0) new_terminal()
    }, [terminal_open])


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

    // The terminal area can live in three places (its "dock"): bottom, right, or embedded as an
    // editor tab. `__terminal__` is the synthetic editor-tab id used in "tab" mode.
    const tab_mode = terminal_open && terminal_dock === "tab"

    const toggle_terminal = useCallback(() => {
        const next = !terminal_open
        set_terminal_open(next)
        if (next && terminal_dock === "tab") set_active("__terminal__")
        if (!next) set_active((a) => (a === "__terminal__" ? null : a))
    }, [terminal_open, terminal_dock])

    const cycle_dock = useCallback(() => {
        const next = terminal_dock === "bottom" ? "right" : terminal_dock === "right" ? "tab" : "bottom"
        if (next === "tab") {
            set_terminal_open(true)
            set_active("__terminal__")
        } else if (terminal_dock === "tab") {
            set_active((a) => (a === "__terminal__" ? null : a))
        }
        set_terminal_dock(next)
    }, [terminal_dock])

    // the terminals UI (a tab strip of terminals + their bodies); rendered either in the docked
    // panel or inside the editor "Terminal" tab. `shown` gates which shell is live/painted.
    const render_terminals = (shown) => html`
        <div class="terminal-tabs">
            <div class="terminal-tab-scroller">
                ${terminals.map(
                    (t) => html`<div class="tab terminal-tab ${t.tid === active_terminal ? "active" : ""}" key=${t.tid}>
                        <button class="title" title=${t.label} onClick=${() => set_active_terminal(t.tid)}>
                            <span class="tab-term-icon">⌨</span>${t.label}
                        </button>
                        <button class="close" title="Close terminal" onClick=${() => close_terminal(t.tid)}>×</button>
                    </div>`
                )}
                <button class="new-terminal-tab" title="New terminal" onClick=${new_terminal}>
                    <span class="nt-icon">⌨</span><span class="nt-plus">＋</span>
                </button>
            </div>
        </div>
        <div class="terminal-bodies">
            ${terminals.map(
                (t) => html`<div key=${t.tid} class="terminal-body ${t.tid === active_terminal ? "active" : ""}">
                    <${TerminalView} tid=${t.tid} cwd=${workspace?.root} visible=${shown && t.tid === active_terminal} />
                </div>`
            )}
        </div>
    `

    // Shut the whole server down from the UI — the terminal-independent way out (the launching
    // terminal may be gone or ssh'd away). The server answers, then stops itself a beat later.
    const shutdown_server = useCallback(async () => {
        if (
            !window.confirm(
                "Shut down the PlutoSpace server?\n\nRunning notebooks and the integrated terminal will stop. SSH remote servers keep running and can be reattached later."
            )
        )
            return
        try {
            await fetch("./api/v1/shutdown", { method: "POST" })
        } catch (e) {}
        document.body.innerHTML =
            '<div style="font: 15px/1.6 system-ui, sans-serif; padding: 3rem; text-align: center; color: #888">PlutoSpace has shut down. You can close this tab.</div>'
    }, [])

    // The opener is "homebase": it shows on first launch (no workspace) and on demand (the "open another
    // workspace" button). Picking a folder spawns a child server in a new tab — it never takes over this
    // tab — so the launcher persists as the place you see and manage every running workspace.
    if (no_workspace || show_opener) {
        return html`<${WorkspaceOpener} on_cancel=${no_workspace ? null : () => set_show_opener(false)} tunneled=${tunneled} />`
    }

    return html`
        <div id="land">
            ${sidebar_hidden
                ? html`<button id="sidebar-reopen" title="Show sidebar" onClick=${() => set_sidebar_hidden(false)}>☰</button>`
                : html`<aside style=${`width: ${sidebar_width}px`}>
                <header class="bubble">
                    <div class="header-row">
                        <button class="land-logo-button" title="Back to homebase (open &amp; manage workspaces)" onClick=${go_home}>
                            <img class="land-logo" src=${logo_url} alt="PlutoSpace" />
                        </button>
                        <div class="header-text">
                            <h1 title=${workspace?.root ?? ""}>Pluto<span class="land-accent">Space</span></h1>
                        </div>
                        <div class="header-buttons">
                            <div class="header-menu" ref=${menu_ref}>
                                <button class="header-button menu-button ${menu_open ? "active" : ""}" title="More actions" aria-haspopup="menu" aria-expanded=${menu_open} onClick=${() => set_menu_open((o) => !o)}><span class="menu-dots"></span></button>
                                ${menu_open
                                    ? html`<div class="header-menu-popover" role="menu">
                                          <button class="header-menu-item danger" role="menuitem" onClick=${() => {
                                              set_menu_open(false)
                                              shutdown_server()
                                          }}>⏻ Shut down server</button>
                                      </div>`
                                    : null}
                            </div>
                            <button class="header-button collapse-button" title="Hide sidebar" onClick=${() => set_sidebar_hidden(true)}><span class="collapse-icon"></span></button>
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
                                ${tab_mode
                                    ? html`<div class="tab terminal-tab ${active === "__terminal__" ? "active" : ""}" key="__terminal__">
                                          <button class="title" title="Terminal" onClick=${() => set_active("__terminal__")}>
                                              <span class="tab-term-icon">⌨</span>Terminal
                                          </button>
                                          <button class="close" title="Hide terminal" onClick=${() => {
        set_terminal_open(false)
        set_active((a) => (a === "__terminal__" ? null : a))
    }}>×</button>
                                      </div>`
                                    : null}
                            </div>
                            <button class="terminal-toggle ${terminal_open ? "active" : ""}" title="Toggle the integrated terminal (runs in the workspace folder)" onClick=${toggle_terminal}>⌨ Terminal</button>
                            ${terminal_open
                                ? html`<button
                                      class="terminal-toggle dock-toggle"
                                      title=${terminal_dock === "bottom"
                                          ? "Move terminal to the right"
                                          : terminal_dock === "right"
                                            ? "Embed terminal as an editor tab"
                                            : "Dock terminal to the bottom"}
                                      onClick=${cycle_dock}
                                  >
                                      ${terminal_dock === "bottom" ? "◨" : terminal_dock === "right" ? "▭" : "⬓"}
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
                            ${tab_mode
                                ? html`<div class="pane terminal-area-pane ${active === "__terminal__" ? "active" : ""}">
                                      ${render_terminals(tab_mode && active === "__terminal__")}
                                  </div>`
                                : null}
                            ${tabs.length === 0 && active !== "__terminal__"
                                ? html`<div class="empty-state">
                                      <p>Open a notebook from the workspace on the left, or create a new one.</p>
                                      <p class="hint">Agents can work here too: edit any notebook file, or use <code>pluto-collab</code>.</p>
                                  </div>`
                                : null}
                        </div>
                    </div>
                    ${terminal_ever_opened.current
                        ? html`
                              <div
                                  id="terminal-resizer"
                                  style=${terminal_open && terminal_dock !== "tab" ? "" : "display: none"}
                                  onPointerDown=${start_terminal_resize}
                              ></div>
                              <div
                                  id="terminal-panel"
                                  class="bubble"
                                  style=${terminal_open && terminal_dock !== "tab"
                                      ? terminal_dock === "bottom"
                                          ? `height: ${terminal_height}px`
                                          : `width: ${terminal_width}px`
                                      : "display: none"}
                              >
                                  ${terminal_dock !== "tab" ? render_terminals(terminal_open && terminal_dock !== "tab") : null}
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
