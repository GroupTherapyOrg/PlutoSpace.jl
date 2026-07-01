# PTYWindows.jl — ConPTY-backed PTY for the PlutoSpace integrated terminal.
#
# The Windows counterpart to PTY.jl (which is openpty()/posix_spawnp() and Unix-only).
# Windows has no openpty; its pseudo-console API is ConPTY (CreatePseudoConsole,
# introduced in Windows 10 1809 / Server 2019), the same primitive VS Code's integrated
# terminal uses under the hood (via node-pty). This module drives it directly through
# kernel32 with `ccall`, exposing the exact same surface as PTY.jl — pty_spawn, pty_write,
# pty_resize!, pty_close!, pty_alive, and a `pty.output` Channel{Vector{UInt8}} — so
# CollabTerminal.jl works identically on both platforms. Exactly one of PTY.jl /
# PTYWindows.jl is included, chosen by `@static Sys.iswindows()` in PlutoSpace.jl.
#
# Wiring (mirrors Microsoft's EchoCon sample):
#   • Two anonymous pipes: one we WRITE keystrokes into, one we READ shell output from.
#   • CreatePseudoConsole(size, in_read, out_write) attaches the ConPTY to the PTY ends.
#   • CreateProcessW with a PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE attribute launches the
#     shell attached to that console; conhost translates its console calls into the VT/ANSI
#     bytes xterm.js expects and writes them to our output pipe.
#
# Output is drained by a cooperative @async reader that polls PeekNamedPipe (non-blocking,
# works on anonymous pipes) and ReadFiles only what's already buffered — so it never blocks
# the Julia scheduler and needs no dedicated OS thread per terminal.

# ── Win32 constants (x64) ──

const _EXTENDED_STARTUPINFO_PRESENT       = UInt32(0x00080000)
const _CREATE_UNICODE_ENVIRONMENT         = UInt32(0x00000400)
const _PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = Csize_t(0x00020016)
const _WAIT_OBJECT_0                       = UInt32(0x00000000)
const _INVALID_HANDLE                      = Ptr{Cvoid}(typemax(UInt))
# STARTUPINFOEXW is STARTUPINFOW (104 bytes on x64) + lpAttributeList pointer → 112 bytes.
const _STARTUPINFOEXW_SIZE = 112
const _STARTUPINFOEXW_ATTRLIST_OFFSET = 104
const _PROCESS_INFORMATION_SIZE = 24  # HANDLE hProcess; HANDLE hThread; DWORD pid; DWORD tid

# ── PTY struct (same interface fields as PTY.jl's) ──

mutable struct PTY
    hpc::Ptr{Cvoid}          # HPCON (pseudo-console handle)
    input_write::Ptr{Cvoid}  # we write keystrokes here → shell stdin
    output_read::Ptr{Cvoid}  # we read shell output here
    hprocess::Ptr{Cvoid}
    hthread::Ptr{Cvoid}
    child_pid::Cint
    rows::Int
    cols::Int
    alive::Bool
    output::Channel{Vector{UInt8}}
    reader_task::Task
    on_data::Union{Function, Nothing}
end

# ── Small Win32 helpers ──

_last_error() = ccall((:GetLastError, "kernel32"), UInt32, ())

function _close_handle(h::Ptr{Cvoid})
    (h == C_NULL || h == _INVALID_HANDLE) && return
    ccall((:CloseHandle, "kernel32"), Cint, (Ptr{Cvoid},), h)
    nothing
end

function _create_pipe()
    rd = Ref{Ptr{Cvoid}}(C_NULL)
    wr = Ref{Ptr{Cvoid}}(C_NULL)
    ok = ccall((:CreatePipe, "kernel32"), Cint,
               (Ptr{Ptr{Cvoid}}, Ptr{Ptr{Cvoid}}, Ptr{Cvoid}, UInt32),
               rd, wr, C_NULL, UInt32(0))
    ok == 0 && error("CreatePipe failed: error=$(_last_error())")
    (rd[], wr[])
end

"Null-terminated UTF-16 for a Win32 wide-string argument."
_cwstr(s::AbstractString) = push!(transcode(UInt16, String(s)), UInt16(0))

# Pack a COORD {SHORT X=cols; SHORT Y=rows} into the DWORD it occupies by value in the
# x64 calling convention — sidesteps by-value struct ABI concerns for CreatePseudoConsole.
_coord(rows::Integer, cols::Integer) = UInt32(cols % UInt16) | (UInt32(rows % UInt16) << 16)

"Quote one argv element per CommandLineToArgvW's rules (spaces, quotes, trailing backslashes)."
function _win_quote(arg::AbstractString)
    s = String(arg)
    (!isempty(s) && !occursin(r"[ \t\"]", s)) && return s
    buf = IOBuffer()
    write(buf, '"')
    bs = 0
    for c in s
        if c == '\\'
            bs += 1
        elseif c == '"'
            write(buf, repeat("\\", 2bs + 1)); write(buf, '"'); bs = 0
        else
            write(buf, repeat("\\", bs)); write(buf, c); bs = 0
        end
    end
    write(buf, repeat("\\", 2bs)); write(buf, '"')
    String(take!(buf))
end

_win_cmdline(argv::Vector{String}) = join(_win_quote.(argv), ' ')

"Build a CREATE_UNICODE_ENVIRONMENT block: sorted, each `K=V` NUL-terminated, a trailing NUL."
function _env_block(extra::Dict{String,String})
    merged = Dict{String,String}()
    for (k, v) in ENV; merged[String(k)] = String(v); end
    for (k, v) in extra; merged[k] = v; end
    block = UInt16[]
    for k in sort!(collect(keys(merged)); by = uppercase)
        append!(block, transcode(UInt16, string(k, "=", merged[k])))
        push!(block, UInt16(0))
    end
    push!(block, UInt16(0))
    block
end

# ── Background reader ──
#
# Cooperative, no dedicated OS thread: PeekNamedPipe tells us how many bytes are buffered
# (and, by returning FALSE, when the write end has closed = shell gone); ReadFile then reads
# only that much, so it never blocks. Idle polling yields to the scheduler every few ms.

function _start_pty_reader(pty::PTY)
    @async begin
        buf   = Vector{UInt8}(undef, 8192)
        avail = Ref{UInt32}(0)
        nread = Ref{UInt32}(0)
        try
            while pty.alive
                ok = ccall((:PeekNamedPipe, "kernel32"), Cint,
                           (Ptr{Cvoid}, Ptr{Cvoid}, UInt32, Ptr{UInt32}, Ptr{UInt32}, Ptr{UInt32}),
                           pty.output_read, C_NULL, UInt32(0), C_NULL, avail, C_NULL)
                if ok == 0            # broken pipe → the shell (and its ConPTY) is gone
                    pty.alive = false
                    break
                end
                if avail[] == 0
                    sleep(0.008)      # idle: yield to the scheduler (~8ms echo latency)
                    continue
                end
                want = min(UInt32(length(buf)), avail[])
                rok = GC.@preserve buf ccall((:ReadFile, "kernel32"), Cint,
                    (Ptr{Cvoid}, Ptr{UInt8}, UInt32, Ptr{UInt32}, Ptr{Cvoid}),
                    pty.output_read, pointer(buf), want, nread, C_NULL)
                if rok == 0 || nread[] == 0
                    pty.alive = false
                    break
                end
                put!(pty.output, buf[1:nread[]])
                pty.on_data !== nothing && pty.on_data()
            end
        catch e
            e isa InvalidStateException || e isa Base.IOError ||
                (pty.alive && @debug "PTY reader error" exception=(e, catch_backtrace()))
        end
        pty.alive = false
    end
end

# ── Spawn ──

"""
    pty_spawn(cmd::Vector{String}; rows=24, cols=80, env=nothing, dir=nothing) → PTY

Spawn `cmd` attached to a new ConPTY. `dir` becomes the child's working directory
(CreateProcessW's lpCurrentDirectory). Output is delivered via `pty.output`; write input
via `pty_write`.
"""
function pty_spawn(cmd::Vector{String}; rows::Int=24, cols::Int=80,
                   env::Union{Dict{String,String}, Nothing}=nothing,
                   dir::Union{String, Nothing}=nothing)
    isempty(cmd) && error("pty_spawn: cmd must not be empty")

    (in_rd,  in_wr)  = _create_pipe()   # shell reads stdin from in_rd; we write to in_wr
    (out_rd, out_wr) = _create_pipe()   # shell writes stdout to out_wr; we read from out_rd

    # Create the pseudo-console attached to the PTY ends of the pipes.
    hpc = Ref{Ptr{Cvoid}}(C_NULL)
    hr = ccall((:CreatePseudoConsole, "kernel32"), Clong,
               (UInt32, Ptr{Cvoid}, Ptr{Cvoid}, UInt32, Ptr{Ptr{Cvoid}}),
               _coord(rows, cols), in_rd, out_wr, UInt32(0), hpc)
    if hr < 0
        foreach(_close_handle, (in_rd, in_wr, out_rd, out_wr))
        error("CreatePseudoConsole failed: HRESULT=0x$(string(reinterpret(UInt32, hr); base=16)) " *
              "(needs Windows 10 1809+ / Server 2019+)")
    end
    # ConPTY dup'd the PTY ends into conhost; drop our copies. Keep in_wr and out_rd.
    _close_handle(in_rd); _close_handle(out_wr)

    # PROC_THREAD_ATTRIBUTE_LIST carrying the pseudo-console (two-call size idiom).
    sz = Ref{Csize_t}(0)
    ccall((:InitializeProcThreadAttributeList, "kernel32"), Cint,
          (Ptr{Cvoid}, UInt32, UInt32, Ptr{Csize_t}), C_NULL, UInt32(1), UInt32(0), sz)
    attr = Vector{UInt8}(undef, sz[])

    si = zeros(UInt8, _STARTUPINFOEXW_SIZE)
    pi = zeros(UInt8, _PROCESS_INFORMATION_SIZE)
    cmdline   = _cwstr(_win_cmdline(cmd))                       # writable wide command line
    cwstr_dir = dir === nothing ? UInt16[] : _cwstr(dir)
    flags     = _EXTENDED_STARTUPINFO_PRESENT
    envblock  = UInt16[]
    if env !== nothing
        envblock = _env_block(env)
        flags |= _CREATE_UNICODE_ENVIRONMENT
    end

    ret = GC.@preserve attr si pi cmdline cwstr_dir envblock begin
        ok = ccall((:InitializeProcThreadAttributeList, "kernel32"), Cint,
                   (Ptr{UInt8}, UInt32, UInt32, Ptr{Csize_t}), attr, UInt32(1), UInt32(0), sz)
        ok == 0 && (ccall((:ClosePseudoConsole, "kernel32"), Cvoid, (Ptr{Cvoid},), hpc[]);
                    _close_handle(in_wr); _close_handle(out_rd);
                    error("InitializeProcThreadAttributeList failed: error=$(_last_error())"))
        ok2 = ccall((:UpdateProcThreadAttribute, "kernel32"), Cint,
                    (Ptr{UInt8}, UInt32, Csize_t, Ptr{Cvoid}, Csize_t, Ptr{Cvoid}, Ptr{Csize_t}),
                    attr, UInt32(0), _PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
                    hpc[], Csize_t(sizeof(Ptr{Cvoid})), C_NULL, C_NULL)
        ok2 == 0 && (ccall((:DeleteProcThreadAttributeList, "kernel32"), Cvoid, (Ptr{UInt8},), attr);
                     ccall((:ClosePseudoConsole, "kernel32"), Cvoid, (Ptr{Cvoid},), hpc[]);
                     _close_handle(in_wr); _close_handle(out_rd);
                     error("UpdateProcThreadAttribute failed: error=$(_last_error())"))

        # STARTUPINFOEXW: cb = full extended size, and lpAttributeList at its trailing slot.
        unsafe_store!(Ptr{UInt32}(pointer(si)), UInt32(_STARTUPINFOEXW_SIZE))
        unsafe_store!(Ptr{Ptr{Cvoid}}(pointer(si) + _STARTUPINFOEXW_ATTRLIST_OFFSET),
                      Ptr{Cvoid}(pointer(attr)))

        dirp = isempty(cwstr_dir) ? C_NULL : pointer(cwstr_dir)
        envp = env === nothing   ? C_NULL : Ptr{Cvoid}(pointer(envblock))
        r = ccall((:CreateProcessW, "kernel32"), Cint,
                  (Ptr{UInt16}, Ptr{UInt16}, Ptr{Cvoid}, Ptr{Cvoid}, Cint, UInt32,
                   Ptr{Cvoid}, Ptr{UInt16}, Ptr{UInt8}, Ptr{UInt8}),
                  C_NULL, pointer(cmdline), C_NULL, C_NULL, Cint(0), flags,
                  envp, dirp, pointer(si), pointer(pi))
        ccall((:DeleteProcThreadAttributeList, "kernel32"), Cvoid, (Ptr{UInt8},), attr)
        r
    end

    if ret == 0
        err = _last_error()
        ccall((:ClosePseudoConsole, "kernel32"), Cvoid, (Ptr{Cvoid},), hpc[])
        _close_handle(in_wr); _close_handle(out_rd)
        error("CreateProcessW failed: error=$err")
    end

    hprocess = GC.@preserve pi unsafe_load(Ptr{Ptr{Cvoid}}(pointer(pi)))
    hthread  = GC.@preserve pi unsafe_load(Ptr{Ptr{Cvoid}}(pointer(pi) + 8))
    pid      = GC.@preserve pi unsafe_load(Ptr{UInt32}(pointer(pi) + 16))

    output = Channel{Vector{UInt8}}(64)
    pty = PTY(hpc[], in_wr, out_rd, hprocess, hthread, Cint(pid), rows, cols, true,
              output, (@async nothing), nothing)
    pty.reader_task = _start_pty_reader(pty)
    pty
end

# ── Write ──

function pty_write(pty::PTY, data::Vector{UInt8})
    isempty(data) && return
    n = Ref{UInt32}(0)
    GC.@preserve data ccall((:WriteFile, "kernel32"), Cint,
                (Ptr{Cvoid}, Ptr{UInt8}, UInt32, Ptr{UInt32}, Ptr{Cvoid}),
                pty.input_write, pointer(data), UInt32(length(data)), n, C_NULL)
    nothing
end

pty_write(pty::PTY, s::String) = pty_write(pty, Vector{UInt8}(codeunits(s)))

# ── Resize ──

function pty_resize!(pty::PTY, rows::Int, cols::Int)
    pty.rows = rows
    pty.cols = cols
    ccall((:ResizePseudoConsole, "kernel32"), Clong,
          (Ptr{Cvoid}, UInt32), pty.hpc, _coord(rows, cols))
    nothing
end

# ── Alive check ──

function pty_alive(pty::PTY)
    pty.alive || return false
    pty.hprocess == C_NULL && return pty.alive
    r = ccall((:WaitForSingleObject, "kernel32"), UInt32,
              (Ptr{Cvoid}, UInt32), pty.hprocess, UInt32(0))
    if r == _WAIT_OBJECT_0   # signaled → process exited
        pty.alive = false
        return false
    end
    true
end

# ── Close ──

function pty_close!(pty::PTY)
    pty.hpc == C_NULL && return
    pty.alive = false
    # Closing the pseudo-console terminates the child and EOFs the output pipe, which stops
    # the reader's PeekNamedPipe loop. Close the channel first so a blocked put! unwinds too.
    ccall((:ClosePseudoConsole, "kernel32"), Cvoid, (Ptr{Cvoid},), pty.hpc)
    try close(pty.output) catch end
    if !istaskdone(pty.reader_task)
        try wait(pty.reader_task) catch end
    end
    _close_handle(pty.input_write)
    _close_handle(pty.output_read)
    if pty.hprocess != C_NULL
        ccall((:TerminateProcess, "kernel32"), Cint, (Ptr{Cvoid}, UInt32), pty.hprocess, UInt32(1))
        ccall((:WaitForSingleObject, "kernel32"), UInt32, (Ptr{Cvoid}, UInt32), pty.hprocess, UInt32(2000))
        _close_handle(pty.hprocess)
    end
    _close_handle(pty.hthread)
    pty.hpc = C_NULL
    pty.input_write = C_NULL
    pty.output_read = C_NULL
    pty.hprocess = C_NULL
    pty.hthread = C_NULL
    nothing
end
