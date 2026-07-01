###
# The PlutoSpace integrated terminal: a WebSocket ⇄ PTY bridge with PERSISTENT sessions.
#
# A client connects a websocket to `/terminal?tid=<id>` (authenticated with the normal
# Pluto secret — cookie or ?secret=…). The shell session belongs to the `tid`, not the
# socket: disconnecting (page refresh, network blip) leaves the shell running; the next
# connection with the same tid replays recent scrollback and reattaches — tmux semantics
# without tmux. Several sockets may attach to one tid (mirrored terminals).
#
# Wire protocol (deliberately trivial, no parser needed on either side):
#   client → server (text frames):   "0:<raw input>"      keystrokes for the shell
#                                    "1:<rows>,<cols>"     terminal was resized
#                                    "2:<ext>:<base64>"    a pasted image (see _handle_paste)
#   server → client (binary frames): raw PTY output bytes  (feed straight to xterm.js)
#
# Shells end when they exit (or the server stops). The scrollback ring holds the last
# $(TERMINAL_SCROLLBACK_LIMIT) bytes for replay on reattach.
###

import Base64

const TERMINAL_SCROLLBACK_LIMIT = 200_000

# Pasted images are written to a per-terminal temp dir (never the workspace) so a CLI agent running in
# the shell — local or, over SSH, on the remote — can open them. Bounded so storage can't grow without
# limit: a hard size cap per paste plus a small ring of the most-recent files, and the whole dir is
# removed when the shell exits.
const TERMINAL_PASTE_MAX_BYTES = 10 * 1024 * 1024
const TERMINAL_PASTE_KEEP = 10

mutable struct CollabTerminal
    pty::PTY
    scrollback::Vector{UInt8}
    scrollback_trimmed::Bool   # the ring has rolled over — its start may be mid-escape-sequence
    clients::Set{Any}
    lock::ReentrantLock
    pump::Task
    cwd::String   # the folder this shell was started in — so we can tell when the workspace changed under it
    paste_dir::String   # per-terminal temp dir for pasted images (created lazily, removed when the shell exits)
end

const COLLAB_TERMINALS = Dict{String,CollabTerminal}()
const COLLAB_TERMINALS_LOCK = ReentrantLock()

"Shell-quote a path for `sh -c`."
_shquote(s::String) = "'" * replace(s, "'" => "'\\''") * "'"

"Filesystem-safe form of a terminal id, for naming its paste temp dir."
function _safe_tid(tid::AbstractString)
    s = filter(c -> isletter(c) || isdigit(c) || c in ('-', '_'), String(tid))
    isempty(s) ? "default" : s
end

"Keep only the `keep` most-recently-modified files in `dir`, deleting the rest. The paste ring."
function _prune_paste_dir(dir::String, keep::Int)
    isdir(dir) || return
    files = filter(isfile, [joinpath(dir, f) for f in readdir(dir)])
    length(files) <= keep && return
    sort!(files; by=mtime)
    for f in files[1:(length(files)-keep)]
        try
            rm(f; force=true)
        catch
        end
    end
end

"""
Handle a pasted image. `payload` is `<ext>:<base64>`: decode it, write it to the terminal's temp dir
(bounded by [`TERMINAL_PASTE_MAX_BYTES`] and a [`TERMINAL_PASTE_KEEP`]-file ring — never the workspace),
and type the file's path into the shell so a CLI agent can open it. The path lands on whichever machine
the shell runs on, so this works identically for a local shell and an SSH-remote one. Malformed or
oversized pastes are silently dropped.
"""
function _handle_paste(t::CollabTerminal, payload::AbstractString)
    p = String(payload)
    sep = findfirst(==(':'), p)
    sep === nothing && return
    ext = lowercase(filter(c -> isletter(c) || isdigit(c), p[1:sep-1]))
    isempty(ext) && (ext = "png")
    bytes = try
        Base64.base64decode(p[sep+1:end])
    catch
        return
    end
    (isempty(bytes) || length(bytes) > TERMINAL_PASTE_MAX_BYTES) && return
    try
        mkpath(t.paste_dir)
        _prune_paste_dir(t.paste_dir, TERMINAL_PASTE_KEEP - 1)
        path = joinpath(t.paste_dir, "paste-$(time_ns()).$(ext)")
        write(path, bytes)
        # type the path (with a trailing space, never a newline — don't submit for the user)
        pty_write(t.pty, path * " ")
    catch
    end
end

"""
Resolve the directory an integrated terminal should open in. Preference order:

 1. a directory the client explicitly asked for — the workspace root it is *currently showing*.
    This is what makes the terminal follow the open workspace, whether that's a local folder or an
    ssh-remote one (the remote's own Land page reports the remote root), and it is robust against the
    shell having been spawned before the workspace was set;
 2. the server's current `workspace_folder`;
 3. the user's home directory, as a last resort.

Anything that isn't an existing directory is skipped.
"""
function _resolve_terminal_cwd(session::ServerSession, requested::Union{Nothing,AbstractString})::String
    for cand in (requested, session.options.server.workspace_folder)
        cand === nothing && continue
        s = String(cand)
        isempty(s) && continue
        p = tamepath(s)
        isdir(p) && return p
    end
    homedir()
end

"Pick the interactive shell exe for a Windows terminal, VS Code-style: PowerShell 7, then
Windows PowerShell, then cmd. Overridable with PLUTOSPACE_SHELL (name on PATH or full path)."
function _windows_shell_exe()::String
    override = get(ENV, "PLUTOSPACE_SHELL", "")
    if !isempty(override)
        return isfile(override) ? override : something(Sys.which(override), override)
    end
    for exe in ("pwsh", "powershell", "cmd")
        p = Sys.which(exe)
        p === nothing || return p
    end
    "cmd.exe"
end

function _spawn_workspace_shell(session::ServerSession, dir::String; rows::Int=24, cols::Int=80)
    # Make this terminal "just work" for any CLI coding agent: the live server's port + secret
    # so tools target THIS session without discovery, and the apps bin (where `pluto-collab`
    # was installed) prepended to PATH defensively.
    port = session.options.server.port
    banner = string(
        "\e[1m🟢🟣🔴 PlutoSpace live session\e[0m — notebooks in this folder are collaborative.\r\n",
        "Edit a notebook .jl and its cells go stale in the browser; run exactly what changed:\r\n",
        "  \e[36mpluto-collab status <nb.jl>\e[0m   ·   \e[36mpluto-collab run <nb.jl> --stale\e[0m\r\n\r\n",
    )

    @static if Sys.iswindows()
        # The agent surface as real environment variables (ConPTY sets them via the process
        # environment block — no shell-syntax differences), and ConPTY sets the working dir
        # directly (lpCurrentDirectory), so no `cd` is needed.
        env = Dict{String,String}(
            "PLUTOSPACE" => "1",
            "PLUTOSPACE_PORT" => (port === nothing ? "" : string(port)),
            "PLUTOSPACE_SECRET" => session.secret,
            "PLUTOSPACE_WORKSPACE" => dir,
            "PATH" => string(apps_bin_dir(), ";", get(ENV, "PATH", "")),
        )
        shell = _windows_shell_exe()
        if endswith(lowercase(shell), "cmd.exe")
            # cmd: no ANSI banner, just open in the workspace — in UTF-8 (chcp 65001) so tools
            # that write raw UTF-8 render correctly.
            pty_spawn([shell, "/K", "chcp 65001 >nul"]; dir=dir, env=env, rows=rows, cols=cols)
        else
            # PowerShell: print the banner, then stay interactive (-NoExit). The banner is
            # base64-encoded so its ANSI/emoji survive command-line quoting intact. The console
            # must be switched to UTF-8 FIRST: Windows PowerShell 5.1 encodes [Console]::Write
            # through the legacy OEM codepage, which turns the banner's emoji into "??????" and
            # the em-dash into "-" — and any child that writes raw UTF-8 would mojibake the same
            # way. (BOM-less UTF8Encoding, or 5.1 prepends a stray ï»¿; InputEncoding in a try
            # because some hosts reject the setter.)
            b64 = Base64.base64encode(banner)
            setup = string(
                "\$e=[Text.UTF8Encoding]::new(\$false); ",
                "try{[Console]::OutputEncoding=\$e; [Console]::InputEncoding=\$e}catch{}; \$OutputEncoding=\$e; ",
                "\$b=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$(b64)')); [Console]::Write(\$b)",
            )
            pty_spawn([shell, "-NoLogo", "-NoExit", "-Command", setup]; dir=dir, env=env, rows=rows, cols=cols)
        end
    else
        shell = get(ENV, "SHELL", Sys.isapple() ? "/bin/zsh" : "/bin/bash")
        exports = join([
            "export PLUTOSPACE=1",
            "export PLUTOSPACE_PORT=$(_shquote(port === nothing ? "" : string(port)))",
            "export PLUTOSPACE_SECRET=$(_shquote(session.secret))",
            "export PLUTOSPACE_WORKSPACE=$(_shquote(dir))",
            "export PATH=$(_shquote(apps_bin_dir())):\"\$PATH\"",
        ], "; ")
        # a login shell, already cd'ed into the workspace, with the agent surface exported + a banner
        cmd = "cd $(_shquote(dir)) && $(exports); printf %s $(_shquote(banner)); exec $(_shquote(shell)) -l"
        pty_spawn(["/bin/sh", "-c", cmd]; rows=rows, cols=cols)
    end
end

"Get the live terminal for this id, or (re)create one. The pump task forwards PTY output to every attached socket and maintains the scrollback ring."
function _get_or_create_terminal(session::ServerSession, tid::String; requested_cwd::Union{Nothing,AbstractString}=nothing, rows::Int=24, cols::Int=80)::CollabTerminal
    lock(COLLAB_TERMINALS_LOCK) do
        target = _resolve_terminal_cwd(session, requested_cwd)
        existing = get(COLLAB_TERMINALS, tid, nothing)
        if existing !== nothing && pty_alive(existing.pty)
            # Reattach to the persistent shell — UNLESS the client is now showing a different
            # workspace than this shell was started in (the user switched/opened a workspace, or
            # the shell predates the workspace being set). Then the shell is in the wrong folder:
            # retire it and start fresh in the open workspace below. A connect that doesn't name a
            # cwd never disturbs a running shell.
            if requested_cwd === nothing || existing.cwd == target
                return existing
            end
            delete!(COLLAB_TERMINALS, tid)
            stale = existing
            @async try
                pty_close!(stale.pty)
            catch
            end
        end

        # Per-instance temp dir (the time_ns suffix keeps it unique): switching workspace retires this
        # shell and starts a new one with the same tid, and we must not let the retired shell's teardown
        # delete the new shell's pasted files.
        paste_dir = joinpath(tempdir(), "plutospace-paste-$(_safe_tid(tid))-$(time_ns())")
        t = CollabTerminal(_spawn_workspace_shell(session, target; rows=rows, cols=cols), UInt8[], false, Set{Any}(), ReentrantLock(), @async(nothing), target, paste_dir)
        t.pump = @asynclog begin
            for data in t.pty.output
                lock(t.lock) do
                    append!(t.scrollback, data)
                    extra = length(t.scrollback) - TERMINAL_SCROLLBACK_LIMIT
                    if extra > 0
                        deleteat!(t.scrollback, 1:extra)
                        t.scrollback_trimmed = true
                    end
                    for client in collect(t.clients)
                        try
                            HTTP.WebSockets.send(client, data)
                        catch
                            delete!(t.clients, client)
                        end
                    end
                end
            end
            # the output channel closed: the shell exited
            lock(t.lock) do
                for client in collect(t.clients)
                    try
                        HTTP.WebSockets.send(client, Vector{UInt8}(codeunits("\r\n\e[2m[shell exited — toggle the terminal to start a new one]\e[0m\r\n")))
                        close(client)
                    catch end
                end
                empty!(t.clients)
            end
            lock(COLLAB_TERMINALS_LOCK) do
                get(COLLAB_TERMINALS, tid, nothing) === t && delete!(COLLAB_TERMINALS, tid)
            end
            # Release the pty's OS resources (fd/handles, reap the child) — the shell exiting on
            # its own does NOT go through the explicit pty_close! path anywhere else.
            try
                pty_close!(t.pty)
            catch
            end
            try
                rm(t.paste_dir; recursive=true, force=true)
            catch
            end
        end
        COLLAB_TERMINALS[tid] = t
        return t
    end
end

function handle_terminal_websocket(ws, session::ServerSession, query::Dict{String,String})
    tid = get(query, "tid", "default")
    cwd = get(query, "cwd", "")  # the workspace root the client is showing — the shell opens here
    # The client's current geometry, so a NEW shell is born at the right size. Spawning at the
    # 24×80 default and resizing on attach makes ConPTY repaint the whole viewport — which lands
    # a duplicate of the banner/first frame in the client's scrollback on Windows.
    q_rows = tryparse(Int, get(query, "rows", ""))
    q_cols = tryparse(Int, get(query, "cols", ""))
    sane = q_rows !== nothing && q_cols !== nothing && 1 < q_rows < 1000 && 9 < q_cols < 1000
    t = try
        _get_or_create_terminal(session, tid; requested_cwd=(isempty(cwd) ? nothing : cwd),
                                rows=(sane ? q_rows : 24), cols=(sane ? q_cols : 80))
    catch e
        # Spawn failed (e.g. Windows older than 10 1809 has no ConPTY). Say so plainly instead
        # of letting the socket close into the frontend's "reload to reattach" message.
        msg = "\r\n\e[31m[could not start a shell: $(sprint(showerror, e))]\e[0m\r\n"
        try HTTP.WebSockets.send(ws, Vector{UInt8}(codeunits(msg))) catch end
        return
    end

    # Attach: replay recent scrollback so the terminal isn't blank after a refresh, then subscribe.
    #
    # The replay is raw recorded bytes, so it only renders correctly in the EXACT grid it was
    # recorded for — full-screen TUIs (Claude Code, vim) position with absolute cursor moves, and
    # replaying them into a different-sized xterm interleaves/mangles frames ("inception"). So the
    # protocol brackets the replay with two TEXT frames (all normal output is binary, so text is
    # unambiguous): first the pty's current geometry — the client resizes its grid to match BEFORE
    # writing the replay — then a completion marker, after which the client re-fits to its panel
    # and resizes the pty, making the live app repaint cleanly at the new size (tmux semantics).
    lock(t.lock) do
        try
            HTTP.WebSockets.send(ws, """{"rows":$(t.pty.rows),"cols":$(t.pty.cols)}""")
            if !isempty(t.scrollback)
                payload = copy(t.scrollback)
                if t.scrollback_trimmed
                    # the ring rolled over: its first bytes may be the tail of an escape sequence,
                    # which would desync the client's VT parser — start at the next line boundary
                    i = findfirst(==(UInt8('\n')), payload)
                    i !== nothing && i < length(payload) && (payload = payload[i+1:end])
                end
                HTTP.WebSockets.send(ws, payload)
            end
            HTTP.WebSockets.send(ws, """{"replayed":true}""")
        catch end
        push!(t.clients, ws)
    end

    try
        for message in ws
            if message isa String
                if startswith(message, "0:")
                    pty_write(t.pty, String(SubString(message, 3)))
                elseif startswith(message, "1:")
                    parts = split(SubString(message, 3), ',')
                    if length(parts) == 2
                        rows = tryparse(Int, parts[1])
                        cols = tryparse(Int, parts[2])
                        # Floor the size: a hidden/animating client can briefly compute a degenerate
                        # tiny geometry, and resizing the PTY to it reflows the shell to a sliver (the
                        # output then sticks in scrollback). No real terminal is usefully this small.
                        if rows !== nothing && cols !== nothing && 1 < rows < 1000 && 9 < cols < 1000
                            pty_resize!(t.pty, rows, cols)
                        end
                    end
                elseif startswith(message, "2:")
                    _handle_paste(t, SubString(message, 3))
                end
            elseif message isa Vector{UInt8}
                pty_write(t.pty, message)
            end
        end
    catch e
        if !(e isa InterruptException || e isa HTTP.WebSockets.WebSocketError || e isa EOFError || e isa Base.IOError)
            @warn "Terminal websocket failed" exception = (e, catch_backtrace())
        end
    finally
        # detach only — the shell keeps running for the next attach
        lock(t.lock) do
            delete!(t.clients, ws)
        end
    end
end
