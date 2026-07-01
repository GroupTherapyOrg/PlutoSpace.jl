# ConPTY low-level diagnostic — replicates pty_spawn's setup step by step, printing each
# syscall's return value + GetLastError, so we can see exactly why the child does not attach
# to the pseudoconsole. Reuses PTYWindows.jl's helpers/constants; does the CreateProcess inline.

Sys.iswindows() || (println("Not Windows — skipping."); exit(0))

const REPO = normpath(joinpath(@__DIR__, ".."))
module W end
Base.include(W, joinpath(REPO, "src", "webserver", "PTYWindows.jl"))

gle() = ccall((:GetLastError, "kernel32"), UInt32, ())
println("sizeof(Ptr)=", sizeof(Ptr{Cvoid}),
        "  EXT=", repr(W._EXTENDED_STARTUPINFO_PRESENT),
        "  PSEUDO=", repr(W._PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE),
        "  SIZE=", W._STARTUPINFOEXW_SIZE, " OFF=", W._STARTUPINFOEXW_ATTRLIST_OFFSET)

(in_rd, in_wr)   = W._create_pipe()
(out_rd, out_wr) = W._create_pipe()
println("pipes: in_rd=", in_rd, " in_wr=", in_wr, " out_rd=", out_rd, " out_wr=", out_wr)

hpc = Ref{Ptr{Cvoid}}(C_NULL)
hr = ccall((:CreatePseudoConsole, "kernel32"), Clong,
           (UInt32, Ptr{Cvoid}, Ptr{Cvoid}, UInt32, Ptr{Ptr{Cvoid}}),
           W._coord(30, 100), in_rd, out_wr, UInt32(0), hpc)
println("CreatePseudoConsole hr=", hr, " (0=S_OK)  hpc=", hpc[])
ccall((:CloseHandle, "kernel32"), Cint, (Ptr{Cvoid},), in_rd)
ccall((:CloseHandle, "kernel32"), Cint, (Ptr{Cvoid},), out_wr)

sz = Ref{Csize_t}(0)
ccall((:InitializeProcThreadAttributeList, "kernel32"), Cint,
      (Ptr{Cvoid}, UInt32, UInt32, Ptr{Csize_t}), C_NULL, UInt32(1), UInt32(0), sz)
println("Init(size) → sz=", sz[])
attr = Vector{UInt8}(undef, sz[])
r2 = ccall((:InitializeProcThreadAttributeList, "kernel32"), Cint,
           (Ptr{UInt8}, UInt32, UInt32, Ptr{Csize_t}), attr, UInt32(1), UInt32(0), sz); e2 = gle()
println("Init(attr) r=", r2, " gle=", e2)
r3 = ccall((:UpdateProcThreadAttribute, "kernel32"), Cint,
           (Ptr{UInt8}, UInt32, Csize_t, Ptr{Cvoid}, Csize_t, Ptr{Cvoid}, Ptr{Csize_t}),
           attr, UInt32(0), W._PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, hpc[], Csize_t(sizeof(Ptr{Cvoid})), C_NULL, C_NULL); e3 = gle()
println("UpdateProcThreadAttribute r=", r3, " gle=", e3, "  (lpValue=hpc=", hpc[], " cbSize=", sizeof(Ptr{Cvoid}), ")")

si = zeros(UInt8, W._STARTUPINFOEXW_SIZE)
pi = zeros(UInt8, W._PROCESS_INFORMATION_SIZE)
cmdline = W._cwstr(W._win_cmdline(["cmd.exe", "/c", "echo DIAG_MARKER_XYZ"]))
dir = W._cwstr("C:\\")
flags = W._EXTENDED_STARTUPINFO_PRESENT
child_pid = UInt32(0)
GC.@preserve si pi attr cmdline dir begin
    unsafe_store!(Ptr{UInt32}(pointer(si)), UInt32(W._STARTUPINFOEXW_SIZE))
    unsafe_store!(Ptr{Ptr{Cvoid}}(pointer(si) + W._STARTUPINFOEXW_ATTRLIST_OFFSET), Ptr{Cvoid}(pointer(attr)))
    cb_read = unsafe_load(Ptr{UInt32}(pointer(si)))
    attr_read = unsafe_load(Ptr{Ptr{Cvoid}}(pointer(si) + W._STARTUPINFOEXW_ATTRLIST_OFFSET))
    println("STARTUPINFOEX: cb=", cb_read, " lpAttributeList=", attr_read, " (want ", Ptr{Cvoid}(pointer(attr)), ")")
    r = ccall((:CreateProcessW, "kernel32"), Cint,
              (Ptr{UInt16}, Ptr{UInt16}, Ptr{Cvoid}, Ptr{Cvoid}, Cint, UInt32,
               Ptr{Cvoid}, Ptr{UInt16}, Ptr{UInt8}, Ptr{UInt8}),
              C_NULL, pointer(cmdline), C_NULL, C_NULL, Cint(0), flags,
              C_NULL, pointer(dir), pointer(si), pointer(pi)); e = gle()
    println("CreateProcessW r=", r, " gle=", e, " flags=", repr(flags))
    global child_pid = unsafe_load(Ptr{UInt32}(pointer(pi) + 16))
end
println("child pid=", child_pid)

buf = Vector{UInt8}(undef, 8192); avail = Ref{UInt32}(0); nread = Ref{UInt32}(0); got = UInt8[]
t0 = time()
while time() - t0 < 5
    ok = ccall((:PeekNamedPipe, "kernel32"), Cint,
               (Ptr{Cvoid}, Ptr{Cvoid}, UInt32, Ptr{UInt32}, Ptr{UInt32}, Ptr{UInt32}),
               out_rd, C_NULL, UInt32(0), C_NULL, avail, C_NULL)
    if ok == 0; println("PeekNamedPipe failed gle=", gle()); break; end
    if avail[] == 0; sleep(0.02); continue; end
    want = min(UInt32(length(buf)), avail[])
    GC.@preserve buf ccall((:ReadFile, "kernel32"), Cint,
        (Ptr{Cvoid}, Ptr{UInt8}, UInt32, Ptr{UInt32}, Ptr{Cvoid}),
        out_rd, pointer(buf), want, nread, C_NULL)
    append!(got, buf[1:nread[]])
end
s = String(copy(got))
println("\nCAPTURED ", length(got), " bytes through our pipe")
println("  contains DIAG_MARKER_XYZ (child attached to ConPTY): ", occursin("DIAG_MARKER_XYZ", s))
println("  repr: ", repr(s))
