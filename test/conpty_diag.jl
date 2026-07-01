# ConPTY attach diagnostic — the child was inheriting the parent's (redirected) std handles
# instead of attaching to the pseudoconsole. Microsoft's fix for a redirected parent is to set
# STARTF_USESTDHANDLES so the child does NOT inherit them. Sources disagree on the exact combo
# (NULL handles vs. FALSE/TRUE bInheritHandles), so try each and see which delivers the child's
# output ("DIAG_MARKER_XYZ") through OUR pipe rather than to the real console.

Sys.iswindows() || (println("Not Windows — skipping."); exit(0))

const REPO = normpath(joinpath(@__DIR__, ".."))
module W end
Base.include(W, joinpath(REPO, "src", "webserver", "PTYWindows.jl"))

const STARTF_USESTDHANDLES = UInt32(0x00000100)
const STARTUPINFO_DWFLAGS_OFFSET = 60   # dwFlags within STARTUPINFOW (x64)

"Full ConPTY spawn of `cmd /c echo DIAG_MARKER_XYZ`, with tunable handle behaviour; returns bytes captured through our output pipe."
function trial(; usestdhandles::Bool, inherit::Bool)
    (in_rd, in_wr)   = W._create_pipe()
    (out_rd, out_wr) = W._create_pipe()
    hpc = Ref{Ptr{Cvoid}}(C_NULL)
    ccall((:CreatePseudoConsole, "kernel32"), Clong,
          (UInt32, Ptr{Cvoid}, Ptr{Cvoid}, UInt32, Ptr{Ptr{Cvoid}}),
          W._coord(30, 100), in_rd, out_wr, UInt32(0), hpc)
    ccall((:CloseHandle, "kernel32"), Cint, (Ptr{Cvoid},), in_rd)
    ccall((:CloseHandle, "kernel32"), Cint, (Ptr{Cvoid},), out_wr)

    sz = Ref{Csize_t}(0)
    ccall((:InitializeProcThreadAttributeList, "kernel32"), Cint,
          (Ptr{Cvoid}, UInt32, UInt32, Ptr{Csize_t}), C_NULL, UInt32(1), UInt32(0), sz)
    attr = Vector{UInt8}(undef, sz[])
    ccall((:InitializeProcThreadAttributeList, "kernel32"), Cint,
          (Ptr{UInt8}, UInt32, UInt32, Ptr{Csize_t}), attr, UInt32(1), UInt32(0), sz)
    ccall((:UpdateProcThreadAttribute, "kernel32"), Cint,
          (Ptr{UInt8}, UInt32, Csize_t, Ptr{Cvoid}, Csize_t, Ptr{Cvoid}, Ptr{Csize_t}),
          attr, UInt32(0), W._PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, hpc[], Csize_t(sizeof(Ptr{Cvoid})), C_NULL, C_NULL)

    si = zeros(UInt8, W._STARTUPINFOEXW_SIZE)
    pi = zeros(UInt8, W._PROCESS_INFORMATION_SIZE)
    cmdline = W._cwstr(W._win_cmdline(["cmd.exe", "/c", "echo DIAG_MARKER_XYZ"]))
    dir = W._cwstr("C:\\")
    GC.@preserve si pi attr cmdline dir begin
        unsafe_store!(Ptr{UInt32}(pointer(si)), UInt32(W._STARTUPINFOEXW_SIZE))
        unsafe_store!(Ptr{Ptr{Cvoid}}(pointer(si) + W._STARTUPINFOEXW_ATTRLIST_OFFSET), Ptr{Cvoid}(pointer(attr)))
        usestdhandles && unsafe_store!(Ptr{UInt32}(pointer(si) + STARTUPINFO_DWFLAGS_OFFSET), STARTF_USESTDHANDLES)
        ccall((:CreateProcessW, "kernel32"), Cint,
              (Ptr{UInt16}, Ptr{UInt16}, Ptr{Cvoid}, Ptr{Cvoid}, Cint, UInt32,
               Ptr{Cvoid}, Ptr{UInt16}, Ptr{UInt8}, Ptr{UInt8}),
              C_NULL, pointer(cmdline), C_NULL, C_NULL, Cint(inherit ? 1 : 0),
              W._EXTENDED_STARTUPINFO_PRESENT, C_NULL, pointer(dir), pointer(si), pointer(pi))
    end

    buf = Vector{UInt8}(undef, 8192); avail = Ref{UInt32}(0); nread = Ref{UInt32}(0); got = UInt8[]
    t0 = time()
    while time() - t0 < 3
        ok = ccall((:PeekNamedPipe, "kernel32"), Cint,
                   (Ptr{Cvoid}, Ptr{Cvoid}, UInt32, Ptr{UInt32}, Ptr{UInt32}, Ptr{UInt32}),
                   out_rd, C_NULL, UInt32(0), C_NULL, avail, C_NULL)
        ok == 0 && break
        if avail[] == 0; sleep(0.02); continue; end
        want = min(UInt32(length(buf)), avail[])
        GC.@preserve buf ccall((:ReadFile, "kernel32"), Cint,
            (Ptr{Cvoid}, Ptr{UInt8}, UInt32, Ptr{UInt32}, Ptr{Cvoid}),
            out_rd, pointer(buf), want, nread, C_NULL)
        append!(got, buf[1:nread[]])
    end
    ccall((:ClosePseudoConsole, "kernel32"), Cvoid, (Ptr{Cvoid},), hpc[])
    ccall((:CloseHandle, "kernel32"), Cint, (Ptr{Cvoid},), in_wr)
    ccall((:CloseHandle, "kernel32"), Cint, (Ptr{Cvoid},), out_rd)
    got
end

for (name, kw) in (
        ("V1 baseline (no USESTDHANDLES, inherit=FALSE)",       (usestdhandles=false, inherit=false)),
        ("V2 USESTDHANDLES + NULL handles, inherit=FALSE",      (usestdhandles=true,  inherit=false)),
        ("V3 USESTDHANDLES + NULL handles, inherit=TRUE",       (usestdhandles=true,  inherit=true)),
    )
    got = trial(; kw...)
    s = String(copy(got))
    hit = occursin("DIAG_MARKER_XYZ", s)
    println("\n### ", name)
    println("    captured ", length(got), " bytes  | child-output-through-pipe: ", hit ? "YES ✅" : "no")
    println("    repr: ", repr(length(s) > 200 ? s[1:200] * "…" : s))
end
