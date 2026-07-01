# PTY.jl — Standalone PTY management for the PlutoSpace integrated terminal.
#
# Vendored from Sessions.jl src/services/pty.jl (itself extracted from Tachikoma.jl),
# same author/org. Provides pty_spawn, pty_write, pty_resize!, pty_close!, pty_alive
# for bridging a shell process to xterm.js via WebSocket. Unix only (macOS, Linux, BSD).

using FileWatching: poll_fd, RawFD

# ── PTY struct ──

mutable struct PTY
    master_fd::Cint
    child_pid::Cint
    rows::Int
    cols::Int
    alive::Bool
    output::Channel{Vector{UInt8}}
    reader_task::Task
    on_data::Union{Function, Nothing}
end

# ── Platform constants ──

const _TIOCSWINSZ = @static (Sys.isapple() || Sys.isbsd()) ? Culong(0x80087467) : Culong(0x5414)
const _O_NONBLOCK = @static (Sys.isapple() || Sys.isbsd()) ? Cint(0x0004) : Cint(0x0800)
const _F_SETFL = Cint(4)
const _F_GETFL = Cint(3)
const _EAGAIN = @static Sys.isapple() ? Cint(35) : Cint(11)
const _POSIX_SPAWN_SETSID = @static Sys.isapple() ? Cshort(0x0400) : Cshort(0x0080)
const _O_RDWR = Cint(2)
const _SPAWN_FA_SIZE = @static Sys.isapple() ? 8 : 80
const _SPAWN_ATTR_SIZE = @static Sys.isapple() ? 8 : 336

function _set_nonblocking(fd::Cint)
    flags = ccall(:fcntl, Cint, (Cint, Cint), fd, _F_GETFL)
    ccall(:fcntl, Cint, (Cint, Cint, Cint), fd, _F_SETFL, flags | _O_NONBLOCK)
end

# ── Background reader ──

function _start_pty_reader(pty::PTY)
    @async begin
        buf = Vector{UInt8}(undef, 8192)
        fd = RawFD(pty.master_fd)
        try
            while pty.alive
                result = poll_fd(fd, 1.0; readable=true, writable=false)
                result.readable || continue
                while true
                    n = GC.@preserve buf ccall(:read, Cssize_t,
                        (Cint, Ptr{UInt8}, Csize_t),
                        pty.master_fd, pointer(buf), Csize_t(length(buf)))
                    if n > 0
                        put!(pty.output, buf[1:n])
                        pty.on_data !== nothing && pty.on_data()
                    elseif n < 0
                        errno = Base.Libc.errno()
                        errno == _EAGAIN && break
                        pty.alive = false
                        break
                    else
                        pty.alive = false
                        break
                    end
                end
            end
        catch e
            e isa InvalidStateException || e isa Base.IOError || (pty.alive && @debug "PTY reader error" exception=(e, catch_backtrace()))
        end
        pty.alive = false
        # Close the output channel so consumers iterating `for data in pty.output` terminate —
        # without this, a naturally-exiting shell leaves its pump task blocked forever (clients
        # never told, fd and child never cleaned up).
        try close(pty.output) catch end
    end
end

# ── Spawn ──

"""
    pty_spawn(cmd::Vector{String}; rows=24, cols=80, env=nothing) → PTY

Spawn a subprocess in a new PTY using openpty() + posix_spawnp().
Output is delivered via `pty.output` Channel. Write input via `pty_write`.
"""
function pty_spawn(cmd::Vector{String}; rows::Int=24, cols::Int=80,
                   env::Union{Dict{String,String}, Nothing}=nothing)
    @static Sys.iswindows() && error("PTY not supported on Windows")
    isempty(cmd) && error("pty_spawn: cmd must not be empty")

    master_fd = Ref{Cint}(-1)
    slave_fd  = Ref{Cint}(-1)
    slave_name = zeros(UInt8, 256)
    ws = UInt16[rows, cols, 0, 0]

    ret = GC.@preserve ws slave_name ccall(:openpty, Cint,
                (Ptr{Cint}, Ptr{Cint}, Ptr{UInt8}, Ptr{Cvoid}, Ptr{UInt16}),
                master_fd, slave_fd, pointer(slave_name), C_NULL, pointer(ws))
    ret == -1 && error("openpty failed: $(Base.Libc.strerror(Base.Libc.errno()))")

    slave_path = GC.@preserve slave_name unsafe_string(pointer(slave_name))
    _set_nonblocking(master_fd[])

    # posix_spawn file actions: close master, open slave → fd 0 (this acquires the controlling
    # terminal, since the child is a fresh session leader via POSIX_SPAWN_SETSID), dup2 to 1/2,
    # then drop the fork-inherited extra slave fd.
    #
    # The parent's slave fd is deliberately kept open across the spawn: on macOS, once ALL slave
    # fds close the pty is revoked and the NEXT open re-initializes it — wiping the winsize that
    # openpty set, so every shell would be born 0×0 (apps that query size at startup then render
    # for a garbage geometry). The child's fork-inherited copy keeps the count nonzero while its
    # open-by-path runs; the parent closes its copy only after posix_spawnp returns.
    file_actions = zeros(UInt8, _SPAWN_FA_SIZE)
    GC.@preserve file_actions begin
        ccall(:posix_spawn_file_actions_init, Cint, (Ptr{UInt8},), pointer(file_actions))
        ccall(:posix_spawn_file_actions_addclose, Cint,
              (Ptr{UInt8}, Cint), pointer(file_actions), master_fd[])
        ccall(:posix_spawn_file_actions_addopen, Cint,
              (Ptr{UInt8}, Cint, Cstring, Cint, Cushort),
              pointer(file_actions), Cint(0), slave_path, _O_RDWR, Cushort(0))
        ccall(:posix_spawn_file_actions_adddup2, Cint,
              (Ptr{UInt8}, Cint, Cint), pointer(file_actions), Cint(0), Cint(1))
        ccall(:posix_spawn_file_actions_adddup2, Cint,
              (Ptr{UInt8}, Cint, Cint), pointer(file_actions), Cint(0), Cint(2))
        slave_fd[] > 2 && ccall(:posix_spawn_file_actions_addclose, Cint,
              (Ptr{UInt8}, Cint), pointer(file_actions), slave_fd[])
    end

    spawn_attr = zeros(UInt8, _SPAWN_ATTR_SIZE)
    GC.@preserve spawn_attr begin
        ccall(:posix_spawnattr_init, Cint, (Ptr{UInt8},), pointer(spawn_attr))
        ccall(:posix_spawnattr_setflags, Cint,
              (Ptr{UInt8}, Cshort), pointer(spawn_attr), _POSIX_SPAWN_SETSID)
    end

    c_strs = [Base.cconvert(Cstring, s) for s in cmd]
    argv = Cstring[Base.unsafe_convert(Cstring, c) for c in c_strs]
    push!(argv, C_NULL)

    env_dict = copy(ENV)
    if env !== nothing
        for (k, v) in env
            env_dict[k] = v
        end
    end
    haskey(env_dict, "TERM") || (env_dict["TERM"] = "xterm-256color")
    env_strings = ["$k=$v" for (k, v) in env_dict]
    env_c_strs = [Base.cconvert(Cstring, s) for s in env_strings]
    envp = Cstring[Base.unsafe_convert(Cstring, c) for c in env_c_strs]
    push!(envp, C_NULL)

    pid = Ref{Cint}(0)
    ret = GC.@preserve file_actions spawn_attr c_strs argv env_c_strs envp ccall(
        :posix_spawnp, Cint,
        (Ptr{Cint}, Cstring, Ptr{UInt8}, Ptr{UInt8}, Ptr{Cstring}, Ptr{Cstring}),
        pid, argv[1], pointer(file_actions), pointer(spawn_attr),
        pointer(argv), pointer(envp))

    GC.@preserve file_actions ccall(:posix_spawn_file_actions_destroy, Cint,
                                     (Ptr{UInt8},), pointer(file_actions))
    GC.@preserve spawn_attr ccall(:posix_spawnattr_destroy, Cint,
                                   (Ptr{UInt8},), pointer(spawn_attr))

    # Now the child exists (fork happened) and holds its own slave reference — safe to drop ours.
    ccall(:close, Cint, (Cint,), slave_fd[])

    if ret != 0
        ccall(:close, Cint, (Cint,), master_fd[])
        error("posix_spawnp failed: $(Base.Libc.strerror(ret))")
    end

    # Belt and braces: re-assert the geometry on the master. On macOS the winsize state is
    # fragile around slave open/close cycles (see above); this is a no-op when already right.
    winsz = UInt16[rows, cols, 0, 0]
    GC.@preserve winsz ccall(:ioctl, Cint, (Cint, Culong, Ptr{Cvoid}...),
                master_fd[], _TIOCSWINSZ, pointer(winsz))

    output = Channel{Vector{UInt8}}(64)
    pty = PTY(master_fd[], pid[], rows, cols, true, output, (@async nothing), nothing)
    pty.reader_task = _start_pty_reader(pty)
    pty
end

# ── Write ──

function pty_write(pty::PTY, data::Vector{UInt8})
    isempty(data) && return
    # The master is O_NONBLOCK, so a single write() can do a SHORT write (or EAGAIN when the tty
    # buffer is full — a big paste, or the typed image path against a shell that isn't draining).
    # A one-shot write ignoring the count would silently drop the tail. Loop until everything is
    # written, yielding on EAGAIN so the reader keeps draining and we don't spin.
    n = length(data)
    off = 0
    GC.@preserve data while off < n
        pty.master_fd == -1 && return
        w = ccall(:write, Cssize_t, (Cint, Ptr{UInt8}, Csize_t),
                  pty.master_fd, pointer(data) + off, Csize_t(n - off))
        if w > 0
            off += w
        elseif w < 0
            errno = Base.Libc.errno()
            errno == _EAGAIN || return   # real error (e.g. EIO on a gone shell): give up quietly
            sleep(0.001)                 # buffer full: let the reader drain, then retry the tail
        else
            return
        end
    end
    nothing
end

pty_write(pty::PTY, s::String) = pty_write(pty, Vector{UInt8}(codeunits(s)))

# ── Resize ──

function pty_resize!(pty::PTY, rows::Int, cols::Int)
    # No-op on a same-size resize (mirrors PTYWindows.jl): skip the gratuitous SIGWINCH when the
    # client re-sends an unchanged geometry on attach.
    (rows == pty.rows && cols == pty.cols) && return
    pty.rows = rows
    pty.cols = cols
    ws = UInt16[rows, cols, 0, 0]
    GC.@preserve ws ccall(:ioctl, Cint,
                (Cint, Culong, Ptr{Cvoid}...),
                pty.master_fd, _TIOCSWINSZ, pointer(ws))
    pty.child_pid > 0 && ccall(:kill, Cint, (Cint, Cint), -pty.child_pid, Cint(28))
    nothing
end

# ── Alive check ──

function pty_alive(pty::PTY)
    pty.alive || return false
    pty.child_pid <= 0 && return pty.alive
    status = Ref{Cint}(0)
    ret = ccall(:waitpid, Cint, (Cint, Ptr{Cint}, Cint),
                pty.child_pid, status, Cint(1))
    if ret == pty.child_pid
        pty.alive = false
        return false
    end
    true
end

# ── Close ──

function pty_close!(pty::PTY)
    # Idempotent + concurrency-safe. Two tasks can call this on the same PTY at once — the
    # workspace-switch retire path does `@async pty_close!(stale.pty)` while that shell's own pump
    # cleanup also calls pty_close! — and a second `ccall(:close)` on an fd number that has since
    # been reused would shut an innocent descriptor. Claim the close by swapping master_fd to -1
    # BEFORE any yield point (the ccalls and wait(reader_task) below all yield). The read-then-set
    # has no yield between it, so under Julia's cooperative @async scheduling exactly one caller
    # wins the claim; the rest return at the guard. Also zero child_pid so only the winner reaps.
    fd = pty.master_fd
    fd == -1 && return
    pty.master_fd = Cint(-1)
    pid = pty.child_pid
    pty.child_pid = Cint(0)
    pty.alive = false
    ccall(:close, Cint, (Cint,), fd)
    try close(pty.output) catch end
    if !istaskdone(pty.reader_task)
        try wait(pty.reader_task) catch end
    end
    if pid > 0
        # Reap first with WNOHANG: if the child already exited (the reader saw EOF) it is a
        # zombie — collect it WITHOUT signaling, because its pid may otherwise be reused and a
        # blind kill() would hit an innocent process. Only a still-running child gets HUP'd.
        status = Ref{Cint}(0)
        r = ccall(:waitpid, Cint, (Cint, Ptr{Cint}, Cint), pid, status, Cint(1))
        if r == 0   # still running
            ccall(:kill, Cint, (Cint, Cint), pid, Cint(1))
            ccall(:waitpid, Cint, (Cint, Ptr{Cint}, Cint), pid, status, Cint(0))
        end
    end
    nothing
end
