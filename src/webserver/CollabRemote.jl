###
# Remote workspaces over SSH (the VS Code Remote-SSH model, EXPERIMENTAL).
#
# Point-and-click from the workspace opener: the LOCAL server orchestrates everything
# under the hood, idempotently —
#   1. reuse: if this host already has a live tunnel, or a PlutoLand server already runs
#      remotely (its connection file says so), just (re)attach. Nothing repeats.
#   2. bootstrap (first contact only): clone the fork to ~/.plutoland/Pluto.jl on the
#      remote and instantiate it.
#   3. start: launch the remote server headless, read its connection file for port+secret.
#   4. tunnel: ssh -N -L <local>:127.0.0.1:<remote>, probe /ping, hand the browser
#      http://localhost:<local>/?secret=… — the ENTIRE Land (files, kernels, terminal,
#      agent API) then runs on the remote with zero further changes.
#
# Keyed SSH only (BatchMode=yes): hosts come from ~/.ssh/config; we never prompt.
###

const REMOTE_BOOTSTRAP_DIR = "~/.plutoland/Pluto.jl"
const REMOTE_FORK_URL = "https://github.com/GroupTherapyOrg/Pluto.jl"
const REMOTE_FORK_BRANCH = "collab"

mutable struct RemoteSession
    host::String
    state::String   # connecting | checking | installing | starting | tunneling | ready | error
    detail::String
    local_port::Int
    secret::String
    tunnel::Union{Base.Process,Nothing}
    task::Union{Task,Nothing}
end

const REMOTE_SESSIONS = Dict{String,RemoteSession}()
const REMOTE_SESSIONS_LOCK = ReentrantLock()

"Run a command on the remote through a login shell (so juliaup/julia are on PATH). Keyed auth only."
function _ssh_run(host::String, cmd::String)::String
    read(`ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new $host -- bash -lc $cmd`, String)
end

"Like `_ssh_run`, but never throws: returns (ok, combined stdout+stderr) so failures are diagnosable."
function _ssh_try(host::String, cmd::String)::Tuple{Bool,String}
    out = IOBuffer()
    proc = Base.run(pipeline(`ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new $host -- bash -lc $cmd`; stdout=out, stderr=out); wait=false)
    wait(proc)
    (success(proc), String(take!(out)))
end

_tail(s::String; n=4) = join(last(split(strip(s), '\n'), n), " · ")

function _parse_remote_registry(reg::String)
    port_m = match(r"\"port\": (\d+)", reg)
    secret_m = match(r"\"secret\": \"([^\"]+)\"", reg)
    (port_m === nothing || secret_m === nothing) && return nothing
    (port=parse(Int, port_m.captures[1]), secret=String(secret_m.captures[1]))
end

_remote_url(r::RemoteSession) = "http://localhost:$(r.local_port)/?secret=$(r.secret)"

function _local_ping_ok(port::Int)::Bool
    try
        resp = HTTP.get("http://127.0.0.1:$port/ping"; connect_timeout=2, readtimeout=4, retry=false, status_exception=false)
        resp.status == 200
    catch
        false
    end
end

function _remote_connect_task!(r::RemoteSession)
    try
        r.state = "connecting"
        r.detail = "reaching $(r.host) with your SSH keys"
        try
            _ssh_run(r.host, "true")
        catch
            r.state = "error"
            r.detail = "cannot reach $(r.host) with key-based SSH (check `ssh $(r.host)` works without a password prompt)"
            return
        end

        r.state = "checking"
        r.detail = "looking for a running PlutoLand on $(r.host)"
        reg = try
            _ssh_run(r.host, "cat ~/.local/state/pluto/servers/*.json 2>/dev/null | head -n 1")
        catch
            ""
        end
        remote = _parse_remote_registry(reg)

        if remote === nothing
            # julia must exist on the remote login-shell PATH before anything else
            ok, out = _ssh_try(r.host, "which julia")
            if !ok
                r.state = "error"
                r.detail = "julia not found on $(r.host) (login shell PATH) — install julia/juliaup there first"
                return
            end

            # idempotent bootstrap: a half-failed previous attempt is cleaned up, a good clone is reused
            ok, out = _ssh_try(r.host, "test -d $(REMOTE_BOOTSTRAP_DIR)/.git && echo present || echo absent")
            if !occursin("present", out)
                r.state = "installing"
                r.detail = "first-time setup on $(r.host): cloning the fork (a minute or two)"
                ok, out = _ssh_try(r.host, "rm -rf $(REMOTE_BOOTSTRAP_DIR) && mkdir -p ~/.plutoland && git clone --depth 1 --branch $(REMOTE_FORK_BRANCH) $(REMOTE_FORK_URL) $(REMOTE_BOOTSTRAP_DIR)")
                if !ok
                    hint = occursin(r"resolve host|Could not resolve|unable to access|Connection timed out|Network is unreachable"i, out) ?
                        " — this node looks like it has NO INTERNET ACCESS (common for HPC compute/GPU nodes). Try your LOGIN node instead, or clone the fork to $(REMOTE_BOOTSTRAP_DIR) there manually." : ""
                    r.state = "error"
                    r.detail = "git clone failed on $(r.host): $(_tail(out))$(hint)"
                    return
                end
                r.detail = "first-time setup on $(r.host): instantiating julia packages (can take a few minutes)"
                ok, out = _ssh_try(r.host, "cd $(REMOTE_BOOTSTRAP_DIR) && julia --project=. -e 'import Pkg; Pkg.instantiate()'")
                if !ok
                    r.state = "error"
                    r.detail = "Pkg.instantiate failed on $(r.host): $(_tail(out))"
                    return
                end
            end

            r.state = "starting"
            r.detail = "starting the PlutoLand server on $(r.host)"
            _ssh_run(r.host, "nohup julia --project=$(REMOTE_BOOTSTRAP_DIR) -e 'import Pluto; Pluto.run(launch_browser=false, on_code_change=\"lazy\")' > ~/.plutoland/server.log 2>&1 < /dev/null & disown; true")
            for _ in 1:90
                sleep(2)
                reg = try
                    _ssh_run(r.host, "cat ~/.local/state/pluto/servers/*.json 2>/dev/null | head -n 1")
                catch
                    ""
                end
                remote = _parse_remote_registry(reg)
                remote === nothing || break
            end
            if remote === nothing
                r.state = "error"
                r.detail = "the remote server did not come up — check julia is installed on $(r.host) and see ~/.plutoland/server.log there"
                return
            end
        end

        r.state = "tunneling"
        r.detail = "opening the SSH tunnel"
        local_port, probe_server = Sockets.listenany(Sockets.localhost, 45200)
        close(probe_server)
        local_port = Int(local_port)
        r.tunnel = Base.run(`ssh -o BatchMode=yes -o ConnectTimeout=8 -o ExitOnForwardFailure=yes -N -L $local_port:127.0.0.1:$(remote.port) $(r.host)`; wait=false)
        ok = false
        for _ in 1:20
            sleep(1)
            if _local_ping_ok(local_port)
                ok = true
                break
            end
            process_exited(r.tunnel) && break
        end
        if !ok
            r.state = "error"
            r.detail = "tunnel did not come up (local port $local_port → $(r.host):$(remote.port))"
            return
        end

        r.local_port = local_port
        r.secret = remote.secret
        # a local connection file so pluto-collab and agents reach the REMOTE workspace transparently
        try
            dir = collab_registry_dir()
            mkpath(dir)
            path = joinpath(dir, "$(local_port).json")
            write(path, """{"pid": $(getpid()), "host": "127.0.0.1", "port": $(local_port), "secret": $(_json_string(remote.secret)), "remote_ssh_host": $(_json_string(r.host)), "pluto_version": $(_json_string(PLUTO_VERSION_STR)), "started_at": $(time())}\n""")
            chmod(path, 0o600)
        catch end
        r.state = "ready"
        r.detail = "connected — the workspace runs on $(r.host)"
    catch e
        r.state = "error"
        r.detail = sprint(showerror, e)
    end
end

"Get-or-create the remote session for a host; idempotent — a live tunnel is reused, a dead one restarted."
function open_remote_session!(host::String)::RemoteSession
    lock(REMOTE_SESSIONS_LOCK) do
        r = get(REMOTE_SESSIONS, host, nothing)
        if r !== nothing
            if r.state == "ready" && r.tunnel !== nothing && !process_exited(r.tunnel) && _local_ping_ok(r.local_port)
                return r # alive: nothing to repeat
            end
            if r.state ∉ ("ready", "error") && r.task !== nothing && !istaskdone(r.task)
                return r # already connecting
            end
        end
        r = RemoteSession(host, "connecting", "", 0, "", nothing, nothing)
        r.task = @asynclog _remote_connect_task!(r)
        REMOTE_SESSIONS[host] = r
        return r
    end
end

function register_collab_remote!(router, session::ServerSession)
    function remote_status_json(r::RemoteSession)
        _json(Pair[
            "host" => r.host,
            "state" => r.state,
            "detail" => r.detail,
            "url" => r.state == "ready" ? _remote_url(r) : nothing,
        ]) * "\n"
    end

    function serve_remote_open(request::HTTP.Request)
        query = HTTP.queryparams(HTTP.URI(request.target))
        haskey(query, "host") || return _api_error(400, "pass ?host=<ssh-config-host>", false)
        host = query["host"]
        occursin(r"^[A-Za-z0-9._@-]+$", host) || return _api_error(400, "invalid host name", false)
        r = open_remote_session!(host)
        HTTP.Response(200, ["Content-Type" => "application/json; charset=utf-8"], remote_status_json(r))
    end
    HTTP.register!(router, "POST", "/api/v1/remote/open", serve_remote_open)

    function serve_remote_status(request::HTTP.Request)
        query = HTTP.queryparams(HTTP.URI(request.target))
        host = get(query, "host", "")
        r = lock(REMOTE_SESSIONS_LOCK) do
            get(REMOTE_SESSIONS, host, nothing)
        end
        r === nothing && return _api_error(404, "no session for $host", false)
        HTTP.Response(200, ["Content-Type" => "application/json; charset=utf-8"], remote_status_json(r))
    end
    HTTP.register!(router, "GET", "/api/v1/remote/status", serve_remote_status)
end
