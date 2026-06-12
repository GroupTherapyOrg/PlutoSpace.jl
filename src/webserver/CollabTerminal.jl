###
# The PlutoLand integrated terminal: a WebSocket ⇄ PTY bridge with PERSISTENT sessions.
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
#   server → client (binary frames): raw PTY output bytes  (feed straight to xterm.js)
#
# Shells end when they exit (or the server stops). The scrollback ring holds the last
# $(TERMINAL_SCROLLBACK_LIMIT) bytes for replay on reattach.
###

const TERMINAL_SCROLLBACK_LIMIT = 200_000

mutable struct CollabTerminal
    pty::PTY
    scrollback::Vector{UInt8}
    clients::Set{Any}
    lock::ReentrantLock
    pump::Task
end

const COLLAB_TERMINALS = Dict{String,CollabTerminal}()
const COLLAB_TERMINALS_LOCK = ReentrantLock()

"Shell-quote a path for `sh -c`."
_shquote(s::String) = "'" * replace(s, "'" => "'\\''") * "'"

function _spawn_workspace_shell(session::ServerSession)
    dir = let w = session.options.server.workspace_folder
        w !== nothing && isdir(tamepath(w)) ? tamepath(w) : homedir()
    end
    shell = get(ENV, "SHELL", Sys.isapple() ? "/bin/zsh" : "/bin/bash")
    # a login shell, already cd'ed into the workspace
    pty_spawn(["/bin/sh", "-c", "cd $(_shquote(dir)) && exec $(_shquote(shell)) -l"])
end

"Get the live terminal for this id, or (re)create one. The pump task forwards PTY output to every attached socket and maintains the scrollback ring."
function _get_or_create_terminal(session::ServerSession, tid::String)::CollabTerminal
    lock(COLLAB_TERMINALS_LOCK) do
        existing = get(COLLAB_TERMINALS, tid, nothing)
        if existing !== nothing && pty_alive(existing.pty)
            return existing
        end

        t = CollabTerminal(_spawn_workspace_shell(session), UInt8[], Set{Any}(), ReentrantLock(), @async(nothing))
        t.pump = @asynclog begin
            for data in t.pty.output
                lock(t.lock) do
                    append!(t.scrollback, data)
                    extra = length(t.scrollback) - TERMINAL_SCROLLBACK_LIMIT
                    extra > 0 && deleteat!(t.scrollback, 1:extra)
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
        end
        COLLAB_TERMINALS[tid] = t
        return t
    end
end

function handle_terminal_websocket(ws, session::ServerSession, query::Dict{String,String})
    tid = get(query, "tid", "default")
    t = _get_or_create_terminal(session, tid)

    # attach: replay recent scrollback so the terminal isn't blank after a refresh, then subscribe
    lock(t.lock) do
        isempty(t.scrollback) || try
            HTTP.WebSockets.send(ws, copy(t.scrollback))
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
                        if rows !== nothing && cols !== nothing && 0 < rows < 1000 && 0 < cols < 1000
                            pty_resize!(t.pty, rows, cols)
                        end
                    end
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
