###
# The PlutoLand integrated terminal: a WebSocket ⇄ PTY bridge.
#
# A client connects a websocket to `/terminal` (authenticated with the normal Pluto
# secret — cookie or ?secret=…) and gets a real login shell running in the workspace
# folder. The wire protocol is deliberately trivial, no parser needed on either side:
#
#   client → server (text frames):   "0:<raw input>"      keystrokes for the shell
#                                    "1:<rows>,<cols>"     terminal was resized
#   server → client (binary frames): raw PTY output bytes  (feed straight to xterm.js)
#
# One PTY per connection; closing the socket closes the shell.
###

"Shell-quote a path for `sh -c`."
_shquote(s::String) = "'" * replace(s, "'" => "'\\''") * "'"

function handle_terminal_websocket(ws, session::ServerSession)
    dir = let w = session.options.server.workspace_folder
        w !== nothing && isdir(tamepath(w)) ? tamepath(w) : homedir()
    end
    shell = get(ENV, "SHELL", Sys.isapple() ? "/bin/zsh" : "/bin/bash")
    # start a login shell, already cd'ed into the workspace
    pty = pty_spawn(["/bin/sh", "-c", "cd $(_shquote(dir)) && exec $(_shquote(shell)) -l"])

    sender = @asynclog try
        for data in pty.output
            HTTP.WebSockets.send(ws, data) # Vector{UInt8} → binary frame
        end
    catch e
        e isa Base.IOError || e isa HTTP.WebSockets.WebSocketError || e isa InvalidStateException || rethrow(e)
    end

    try
        for message in ws
            if message isa String
                if startswith(message, "0:")
                    pty_write(pty, String(SubString(message, 3)))
                elseif startswith(message, "1:")
                    parts = split(SubString(message, 3), ',')
                    if length(parts) == 2
                        rows = tryparse(Int, parts[1])
                        cols = tryparse(Int, parts[2])
                        if rows !== nothing && cols !== nothing && 0 < rows < 1000 && 0 < cols < 1000
                            pty_resize!(pty, rows, cols)
                        end
                    end
                end
            elseif message isa Vector{UInt8}
                pty_write(pty, message)
            end
        end
    catch e
        if !(e isa InterruptException || e isa HTTP.WebSockets.WebSocketError || e isa EOFError || e isa Base.IOError)
            @warn "Terminal websocket failed" exception = (e, catch_backtrace())
        end
    finally
        pty_close!(pty)
    end
end
