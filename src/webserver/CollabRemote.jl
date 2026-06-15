###
# Remote workspaces over SSH (the VS Code Remote-SSH model, EXPERIMENTAL).
#
# Point-and-click from the workspace opener: the LOCAL server orchestrates everything
# under the hood, idempotently —
#   1. reuse: if this host already has a live tunnel, or a PlutoSpace server already runs
#      remotely (its connection file says so), just (re)attach. Nothing repeats.
#   2. bootstrap (first contact only): clone the fork to ~/.plutospace/Pluto.jl on the
#      remote and instantiate it.
#   3. start: launch the remote server headless, read its connection file for port+secret.
#   4. tunnel: ssh -N -L <local>:127.0.0.1:<remote>, probe /ping, hand the browser
#      http://localhost:<local>/?secret=… — the ENTIRE Land (files, kernels, terminal,
#      agent API) then runs on the remote with zero further changes.
#
# Keyed SSH only (BatchMode=yes): hosts come from ~/.ssh/config; we never prompt.
###

const REMOTE_BOOTSTRAP_DIR = "~/.plutospace/Pluto.jl"
const REMOTE_FORK_URL = "https://github.com/GroupTherapyOrg/PlutoSpace.jl"
const REMOTE_FORK_BRANCH = "main"

mutable struct RemoteSession
    host::String
    state::String   # connecting | checking | installing | starting | tunneling | ready | error
    detail::String
    local_port::Int
    secret::String
    julia::String   # absolute path of julia on the remote, once discovered
    tunnel::Union{Base.Process,Nothing}
    task::Union{Task,Nothing}
end

const REMOTE_SESSIONS = Dict{String,RemoteSession}()
const REMOTE_SESSIONS_LOCK = ReentrantLock()

# ssh joins its argument vector into ONE space-separated string and the remote shell
# re-splits it — so the command must be shell-quoted by US to survive the trip as a
# single `bash -lc` argument. (Without this, `bash -lc rm -rf x` runs bare `rm`.)
_ssh_command(host::String, cmd::String) =
    `ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new $host -- bash -lc $(_shquote(cmd))`

"Run a command on the remote through a login shell (so juliaup/julia are on PATH). Keyed auth only."
function _ssh_run(host::String, cmd::String)::String
    read(_ssh_command(host, cmd), String)
end

"Like `_ssh_run`, but never throws: returns (ok, combined stdout+stderr) so failures are diagnosable."
function _ssh_try(host::String, cmd::String)::Tuple{Bool,String}
    out = IOBuffer()
    proc = Base.run(pipeline(_ssh_command(host, cmd); stdout=out, stderr=out); wait=false)
    wait(proc)
    (success(proc), String(take!(out)))
end

_tail(s::String; n=4) = join(last(split(strip(s), '\n'), n), " · ")

# julia is often invisible to non-interactive login shells on clusters (module load / .bashrc
# only happen interactively) — so hunt for it and use the ABSOLUTE path from then on.
const _FIND_JULIA_SNIPPET = raw"""
# prefer a REAL julia binary over the juliaup shim: the shim takes juliaup's config lock
# and may block forever on a hung self-update (e.g. on internet-less compute nodes)
p=$(ls -d "$HOME"/.julia/juliaup/julia-*/bin/julia 2>/dev/null | sort -V | tail -n 1)
[ -z "$p" ] && p=$(command -v julia 2>/dev/null)
case "$p" in *"/.juliaup/bin/"*) real=$(ls -d "$HOME"/.julia/juliaup/julia-*/bin/julia 2>/dev/null | sort -V | tail -n 1); [ -n "$real" ] && p="$real" ;; esac
[ -z "$p" ] && [ -x "$HOME/.juliaup/bin/julia" ] && p="$HOME/.juliaup/bin/julia"
[ -z "$p" ] && [ -x "$HOME/.local/bin/julia" ] && p="$HOME/.local/bin/julia"
[ -z "$p" ] && p=$(bash -ic 'command -v julia' 2>/dev/null | tail -n 1)
case "$p" in /*) echo "JULIA:$p" ;; *) echo "JULIA:" ;; esac
"""

function _find_remote_julia(host::String)::String
    ok, out = _ssh_try(host, _FIND_JULIA_SNIPPET)
    m = match(r"JULIA:(\S+)", out)
    m === nothing ? "" : String(m.captures[1])
end

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

# A registry file can outlive the server that wrote it: HPC jobs end, nodes reboot, and a
# SIGKILL'd server never gets to delete its own connection file. Reusing such a stale file
# tunnels forever to a dead port ("tunnel did not come up"). So before trusting a registry,
# confirm something is actually answering on the remote loopback port — curl /ping when
# available (truest: confirms a live Pluto), else a dependency-free bash /dev/tcp probe.
function _remote_server_alive(host::String, port::Int)::Bool
    probe = """
    if command -v curl >/dev/null 2>&1; then
      curl -fsS -m 4 -o /dev/null http://127.0.0.1:$(port)/ping && echo __LIVE__ || echo __DEAD__
    else
      (exec 3<>/dev/tcp/127.0.0.1/$(port)) 2>/dev/null && echo __LIVE__ || echo __DEAD__
    fi
    """
    _, out = _ssh_try(host, probe)
    occursin("__LIVE__", out)
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
        r.detail = "looking for a running PlutoSpace on $(r.host)"
        reg = try
            _ssh_run(r.host, "cat ~/.local/state/pluto/servers/*.json 2>/dev/null | head -n 1")
        catch
            ""
        end
        remote = _parse_remote_registry(reg)

        # Don't trust a connection file whose server has since died — clear the stale file and
        # fall through to a fresh bootstrap/start, so reconnecting "just works" (the VS Code
        # Remote-SSH feel) instead of tunneling to a corpse.
        if remote !== nothing && !_remote_server_alive(r.host, remote.port)
            r.detail = "clearing a stale PlutoSpace registry on $(r.host) (port $(remote.port) is dead)"
            _ssh_try(r.host, "rm -f ~/.local/state/pluto/servers/$(remote.port).json")
            remote = nothing
        end

        if remote === nothing
            # find julia (absolute path) — checks PATH, juliaup, ~/.local/bin, and an interactive shell (for module/.bashrc setups)
            r.julia = _find_remote_julia(r.host)
            if isempty(r.julia)
                r.state = "error"
                r.detail = "julia not found on $(r.host) — tried the login-shell PATH, ~/.juliaup/bin, ~/.local/bin, and an interactive shell. Install juliaup there, or add 'module load julia' to your ~/.bash_profile."
                return
            end

            # idempotent bootstrap with a COMPLETION MARKER (the VS Code Remote-SSH pattern):
            # the install only counts once instantiate finished; a clone without the marker
            # resumes at instantiate, a missing clone starts over.
            ok, out = _ssh_try(r.host, "test -f ~/.plutospace/.install_ok && echo done; test -d $(REMOTE_BOOTSTRAP_DIR)/.git && echo cloned")
            install_done = occursin("done", out)
            cloned = occursin("cloned", out)
            if !install_done
                r.state = "installing"
                if !cloned
                    r.detail = "first-time setup on $(r.host): cloning the fork (a minute or two)"
                    ok, out = _ssh_try(r.host, "rm -rf $(REMOTE_BOOTSTRAP_DIR) && mkdir -p ~/.plutospace && git clone --depth 1 --branch $(REMOTE_FORK_BRANCH) $(REMOTE_FORK_URL) $(REMOTE_BOOTSTRAP_DIR)")
                    if !ok
                        hint = occursin(r"resolve host|Could not resolve|unable to access|Connection timed out|Network is unreachable"i, out) ?
                            " — this node looks like it has NO INTERNET ACCESS (common for HPC compute/GPU nodes). Try your LOGIN node instead, or clone the fork to $(REMOTE_BOOTSTRAP_DIR) there manually." : ""
                        r.state = "error"
                        r.detail = "git clone failed on $(r.host): $(_tail(out))$(hint)"
                        return
                    end
                end
                # run the slow step DETACHED on the remote (nohup + pidfile + log): it survives
                # connection drops and local restarts; we just poll for the completion marker.
                # If an install is already running (e.g. we reconnected), attach to it instead.
                _, out = _ssh_try(r.host, "kill -0 \$(cat ~/.plutospace/install.pid 2>/dev/null) 2>/dev/null && echo alive || echo dead")
                if !occursin("alive", out)
                    launch = """
                    mkdir -p ~/.plutospace
                    rm -f ~/.plutospace/.install_ok
                    nohup sh -c 'cd "\$HOME/.plutospace/Pluto.jl" && $(r.julia) --project=. -e "import Pkg; Pkg.instantiate()" && touch "\$HOME/.plutospace/.install_ok"' > ~/.plutospace/install.log 2>&1 < /dev/null &
                    echo \$! > ~/.plutospace/install.pid
                    echo launched
                    """
                    ok, out = _ssh_try(r.host, launch)
                    if !ok || !occursin("launched", out)
                        r.state = "error"
                        r.detail = "could not start the install on $(r.host): $(_tail(out))"
                        return
                    end
                end
                started = time()
                while true
                    sleep(5)
                    elapsed = round(Int, (time() - started) / 60)
                    # PROOF over promises: stream the live install log line into the banner
                    _, out = _ssh_try(r.host, "test -f ~/.plutospace/.install_ok && echo __DONE__; kill -0 \$(cat ~/.plutospace/install.pid 2>/dev/null) 2>/dev/null && echo __ALIVE__; tail -n 1 ~/.plutospace/install.log 2>/dev/null")
                    occursin("__DONE__", out) && break
                    log_line = strip(replace(replace(out, "__ALIVE__" => ""), "__DONE__" => ""))
                    if occursin("Juliaup configuration is locked", out)
                        _ssh_try(r.host, "kill -9 \$(cat ~/.plutospace/install.pid 2>/dev/null) 2>/dev/null; rm -f ~/.plutospace/install.pid")
                        r.state = "error"
                        r.detail = "the juliaup shim deadlocked on its config lock on $(r.host) (often a hung self-update on an internet-less node) — retry: the real julia binary will be used directly"
                        return
                    end
                    if !occursin("__ALIVE__", out)
                        _, log = _ssh_try(r.host, "tail -n 6 ~/.plutospace/install.log 2>/dev/null")
                        r.state = "error"
                        r.detail = "Pkg.instantiate failed on $(r.host): $(_tail(log))"
                        return
                    end
                    r.detail = "installing on $(r.host) ($(elapsed) min): $(isempty(log_line) ? "starting up…" : last(log_line, 110))"
                    if time() - started > 45 * 60
                        r.state = "error"
                        r.detail = "install on $(r.host) still not finished after 45 minutes — check ~/.plutospace/install.log there"
                        return
                    end
                end
            end

            r.state = "starting"
            r.detail = "starting the PlutoSpace server on $(r.host)"
            _ssh_run(r.host, "nohup $(r.julia) --project=$(REMOTE_BOOTSTRAP_DIR) -e 'm = try Base.require(Main, :PlutoSpace) catch; Base.require(Main, :Pluto) end; m.run(launch_browser=false)' > ~/.plutospace/server.log 2>&1 < /dev/null & disown; true")
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
                r.detail = "the remote server did not come up — see ~/.plutospace/server.log on $(r.host)"
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
        r = RemoteSession(host, "connecting", "", 0, "", "", nothing, nothing)
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
