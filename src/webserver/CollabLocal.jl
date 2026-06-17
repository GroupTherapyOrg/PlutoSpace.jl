###
# Local multi-workspace: the hub server spawns ONE child PlutoSpace server per local workspace folder
# (its own OS process, own port, own secret), each opened in its own browser tab. This is the SSH-remote
# model (see CollabRemote.jl) MINUS the SSH hop and tunnel — everything is already local: julia and the
# project are here, there's no bootstrap/install, and the browser reaches the child on 127.0.0.1 directly.
#
# The point: each child is a vanilla `PlutoSpace.run(workspace=…)` — an individual server behaves exactly
# like Pluto always has. ALL the multi-workspace orchestration lives out here in the wrapper, never inside
# Pluto. (Per-port cookie scoping — see Authentication.jl — lets the hub and every child coexist in the
# browser, each with its own secret.)
#
# Lifecycle (chosen): closing a workspace TAB leaves its child running, so reopening from the launcher
# reattaches instantly with notebooks still alive (matched by the "workspace" field every server writes
# into its connection file). An explicit "shut down this workspace" stops one child; quitting the hub
# reaps them all — local processes aren't meant to outlive the app that launched them.
###

mutable struct LocalSession
    path::String     # workspace folder (absolute, tamepath'd) — the dict key
    state::String    # starting | ready | error
    detail::String
    port::Int
    secret::String
    proc::Union{Base.Process,Nothing}  # nothing when we reattached to a child we didn't spawn
    task::Union{Task,Nothing}
    cancelled::Bool  # set by the UI to abort an in-flight spawn (the spawn task checks it and bails)
end

const LOCAL_SESSIONS = Dict{String,LocalSession}()
const LOCAL_SESSIONS_LOCK = ReentrantLock()

_local_session_url(s::LocalSession) = "http://localhost:$(s.port)/?secret=$(s.secret)"

# Find a LIVE child server already serving `path` on THIS node, so a reopened tab reattaches (and a
# crashed-and-restarted hub self-heals) instead of spawning a duplicate. Every server records its
# workspace in its connection file (CollabAPI.write_collab_registry_file); we match on that, restrict to
# this node (shared $HOME on a cluster holds other nodes' files too), and confirm it actually answers.
function _find_local_server(path::String)
    want = tamepath(path)
    me = gethostname()
    dir = collab_registry_dir()
    isdir(dir) || return nothing
    for name in readdir(dir)
        endswith(name, ".json") || continue
        txt = try
            read(joinpath(dir, name), String)
        catch
            continue
        end
        node_m = match(r"\"node\": \"([^\"]+)\"", txt)
        node_m !== nothing && String(node_m.captures[1]) != me && continue
        ws_m = match(r"\"workspace\": \"([^\"]+)\"", txt)
        ws_m === nothing && continue
        tamepath(String(ws_m.captures[1])) == want || continue
        port_m = match(r"\"port\": (\d+)", txt)
        secret_m = match(r"\"secret\": \"([^\"]+)\"", txt)
        (port_m === nothing || secret_m === nothing) && continue
        port = parse(Int, port_m.captures[1])
        _local_ping_ok(port) || continue   # don't adopt a corpse (stale file → tunnel/redirect to a dead port)
        return (port=port, secret=String(secret_m.captures[1]))
    end
    nothing
end

# Launch (or reattach to) the child server for one workspace, off the request thread. Mirrors
# _remote_connect_task! but local: no SSH, no install — just spawn `julia --project=… -e 'run(workspace=…)'`
# and wait for its connection file to appear, then hand back port + secret.
function _local_spawn_task!(s::LocalSession)
    logfile = joinpath(tempdir(), "plutospace-workspace-$(getpid())-$(string(hash(s.path), base=16)).log")
    try
        # Already up (tab reopened, or a previous hub left it running)? Reattach — never duplicate.
        existing = _find_local_server(s.path)
        if existing !== nothing
            s.port = existing.port
            s.secret = existing.secret
            s.state = "ready"
            s.detail = "reattached — this workspace was already running"
            return
        end

        s.state = "starting"
        s.detail = "starting a PlutoSpace server for $(basename(s.path))"

        # Reproduce the hub's own environment for the child: same julia, same active project, so the child
        # imports PlutoSpace from a precompiled depot (fast — no recompile). The workspace path rides in an
        # ENV var, never interpolated into the -e code, so any folder name survives intact.
        proj = something(Base.active_project(), "")
        projdir = isempty(proj) ? pkgdir(@__MODULE__) : dirname(proj)
        env = copy(ENV)
        env["PLUTOSPACE_CHILD_WORKSPACE"] = s.path
        delete!(env, "JULIA_LOAD_PATH")  # don't leak the app's load path into the child (matches worker/terminal hygiene)
        code = "m = try Base.require(Main, :PlutoSpace) catch; Base.require(Main, :Pluto) end; m.run(workspace=ENV[\"PLUTOSPACE_CHILD_WORKSPACE\"], launch_browser=false)"
        cmd = setenv(`$(Base.julia_cmd()) --project=$(projdir) -e $(code)`, env)
        s.proc = Base.run(pipeline(cmd; stdin=devnull, stdout=logfile, stderr=logfile); wait=false)
        # Cancelled in the window before/just-after spawn? Don't leave the child orphaned.
        if s.cancelled
            try; process_exited(s.proc) || kill(s.proc); catch; end
            s.state = "error"; s.detail = "canceled"
            return
        end

        # Poll for the child's connection file (it writes one once the HTTP server is listening). The hub's
        # project is already precompiled, so this is load latency (seconds), not a compile.
        for _ in 1:180
            sleep(1)
            if s.cancelled
                try; process_exited(s.proc) || kill(s.proc); catch; end
                s.state = "error"; s.detail = "canceled"
                return
            end
            found = _find_local_server(s.path)
            if found !== nothing
                s.port = found.port
                s.secret = found.secret
                s.state = "ready"
                s.detail = "ready — workspace runs on this machine"
                return
            end
            if s.proc !== nothing && process_exited(s.proc)
                s.state = "error"
                s.detail = "the workspace server for $(basename(s.path)) exited before it came up — see $(logfile)"
                return
            end
        end
        s.state = "error"
        s.detail = "the workspace server for $(basename(s.path)) did not come up in time — see $(logfile)"
    catch e
        s.state = "error"
        s.detail = sprint(showerror, e)
    end
end

"Get-or-create the local session for a workspace folder; idempotent — a live child is reused, a dead one respawned."
function open_local_session!(path::String)::LocalSession
    path = tamepath(path)
    lock(LOCAL_SESSIONS_LOCK) do
        s = get(LOCAL_SESSIONS, path, nothing)
        if s !== nothing
            if s.state == "ready" && _local_ping_ok(s.port)
                return s # alive: reuse
            end
            if s.state ∉ ("ready", "error") && s.task !== nothing && !istaskdone(s.task)
                return s # already starting
            end
        end
        s = LocalSession(path, "starting", "", 0, "", nothing, nothing, false)
        s.task = @asynclog _local_spawn_task!(s)
        LOCAL_SESSIONS[path] = s
        return s
    end
end

"Shut down the child server for one workspace: ask it to stop cleanly (it removes its own registry + notebooks), then make sure the process is gone, and forget the session."
function shutdown_local_session!(path::String)
    path = tamepath(path)
    s = lock(LOCAL_SESSIONS_LOCK) do
        get(LOCAL_SESSIONS, path, nothing)
    end
    s === nothing || (s.cancelled = true) # also aborts an in-flight spawn task (cancel during "starting")
    # Works for a child we spawned AND for one we only reattached to (no proc handle): the graceful path
    # is its own /api/v1/shutdown (secret-gated), which fires the child's on_shutdown.
    found = if s !== nothing && s.port != 0
        (port=s.port, secret=s.secret)
    else
        _find_local_server(path)
    end
    if found !== nothing
        try
            HTTP.post("http://127.0.0.1:$(found.port)/api/v1/shutdown?secret=$(HTTP.escapeuri(found.secret))";
                connect_timeout=3, readtimeout=4, retry=false, status_exception=false)
        catch
        end
    end
    if s !== nothing && s.proc !== nothing
        t = s.proc
        try
            if !process_exited(t)
                sleep(0.5)
                process_exited(t) || kill(t)
            end
        catch
        end
    end
    lock(LOCAL_SESSIONS_LOCK) do
        delete!(LOCAL_SESSIONS, path)
    end
    nothing
end

"""
Stop every child workspace server. Called on hub shutdown: unlike SSH remotes (left running to reattach),
local children live on this machine and shouldn't outlive the app that launched them.
"""
function close_all_local_sessions()
    paths = lock(LOCAL_SESSIONS_LOCK) do
        collect(keys(LOCAL_SESSIONS))
    end
    for p in paths
        try
            shutdown_local_session!(p)
        catch
        end
    end
end

function register_collab_local!(router, session::ServerSession)
    function local_status_json(s::LocalSession)
        _json(Pair[
            "path" => s.path,
            "state" => s.state,
            "detail" => s.detail,
            "url" => s.state == "ready" ? _local_session_url(s) : nothing,
        ]) * "\n"
    end

    function serve_local_open(request::HTTP.Request)
        query = HTTP.queryparams(HTTP.URI(request.target))
        haskey(query, "path") || return _api_error(400, "pass ?path=/abs/folder", false)
        path = tamepath(query["path"])
        isdir(path) || return _api_error(400, "not a directory: $path", false)
        s = open_local_session!(path)
        HTTP.Response(200, ["Content-Type" => "application/json; charset=utf-8"], local_status_json(s))
    end
    HTTP.register!(router, "POST", "/api/v1/local/open", serve_local_open)

    function serve_local_status(request::HTTP.Request)
        query = HTTP.queryparams(HTTP.URI(request.target))
        path = tamepath(get(query, "path", ""))
        s = lock(LOCAL_SESSIONS_LOCK) do
            get(LOCAL_SESSIONS, path, nothing)
        end
        s === nothing && return _api_error(404, "no local session for $path", false)
        HTTP.Response(200, ["Content-Type" => "application/json; charset=utf-8"], local_status_json(s))
    end
    HTTP.register!(router, "GET", "/api/v1/local/status", serve_local_status)

    # The launcher uses this to show which workspaces are live (so they reattach in one click).
    function serve_local_list(request::HTTP.Request)
        items = lock(LOCAL_SESSIONS_LOCK) do
            Vector{Pair}[
                Pair[
                    "path" => s.path,
                    "state" => s.state,
                    "url" => s.state == "ready" ? _local_session_url(s) : nothing,
                ]
                for s in values(LOCAL_SESSIONS)
            ]
        end
        HTTP.Response(200, ["Content-Type" => "application/json; charset=utf-8"], _json(items) * "\n")
    end
    HTTP.register!(router, "GET", "/api/v1/local/list", serve_local_list)

    function serve_local_shutdown(request::HTTP.Request)
        query = HTTP.queryparams(HTTP.URI(request.target))
        haskey(query, "path") || return _api_error(400, "pass ?path=/abs/folder", false)
        path = tamepath(query["path"])
        # Respond first, tear down on a short delay (the child's shutdown is itself async).
        @async begin
            sleep(0.2)
            try
                shutdown_local_session!(path)
            catch
            end
        end
        HTTP.Response(200, ["Content-Type" => "application/json; charset=utf-8"], _json(Pair["status" => "shutting_down", "path" => path]) * "\n")
    end
    HTTP.register!(router, "POST", "/api/v1/local/shutdown", serve_local_shutdown)
end
