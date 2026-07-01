# Standalone Windows ConPTY smoke test for src/webserver/PTYWindows.jl.
#
# Runs the ConPTY PTY layer directly (no PlutoSpace package load, no deps to instantiate —
# PTYWindows.jl only needs Base + kernel32), so Windows CI iterates fast and pinpoints where
# terminal output is lost: the ConPTY core (Test 1) vs. the PowerShell/banner invocation the
# real _spawn_workspace_shell uses (Tests 2–3). Rich diagnostics are printed either way.

import Base64

if !Sys.iswindows()
    println("Not Windows — skipping ConPTY tests (this file only means anything on Windows).")
    exit(0)
end

const REPO = normpath(joinpath(@__DIR__, ".."))
module W end
Base.include(W, joinpath(REPO, "src", "webserver", "PTYWindows.jl"))
println("Included PTYWindows.jl OK on ", Sys.MACHINE)

"Read from a PTY's output channel until `want` is seen or `timeout` seconds pass."
function drain(pty; timeout = 6.0, want = "")
    got = UInt8[]
    t0 = time()
    while time() - t0 < timeout
        if isready(pty.output)
            append!(got, take!(pty.output))
            (!isempty(want) && occursin(want, String(copy(got)))) && break
        else
            (!pty.alive && !isready(pty.output)) && break  # child gone + drained
            sleep(0.02)
        end
    end
    got
end

fails = String[]
check(cond, msg) = (println(cond ? "  PASS  " : "  FAIL  ", msg); cond || push!(fails, msg))
ps_exe() = something(Sys.which("pwsh"), Sys.which("powershell"), "powershell.exe")

println("\n== Test 1: cmd.exe echo — ConPTY core (spawn + read) ==")
try
    pty = W.pty_spawn(["cmd.exe", "/c", "echo hello_conpty_marker"]; dir = "C:\\")
    println("  spawned child_pid=", pty.child_pid, " alive=", pty.alive)
    out = drain(pty; timeout = 10, want = "hello_conpty_marker")
    println("  received ", length(out), " bytes: ", repr(String(copy(out))))
    check(occursin("hello_conpty_marker", String(out)), "cmd.exe output reached the reader")
    W.pty_close!(pty)
catch e
    println("  EXCEPTION: ", sprint(showerror, e))
    push!(fails, "cmd.exe spawn threw")
end

println("\n== Test 2: PowerShell interactive — write + read echo ==")
try
    exe = ps_exe()
    pty = W.pty_spawn([exe, "-NoLogo", "-NoExit", "-Command", "Write-Host READY_MARKER"]; dir = "C:\\")
    println("  spawned ", exe, " child_pid=", pty.child_pid)
    out = drain(pty; timeout = 15, want = "READY_MARKER")
    println("  startup: ", length(out), " bytes: ", repr(String(copy(out))))
    check(occursin("READY_MARKER", String(out)), "powershell produced startup output")
    W.pty_write(pty, "echo write_roundtrip_123\r\n")
    out2 = drain(pty; timeout = 10, want = "write_roundtrip_123")
    println("  after write: ", length(out2), " bytes: ", repr(String(copy(out2))))
    check(occursin("write_roundtrip_123", String(out2)), "powershell echoed our written command")
    W.pty_resize!(pty, 40, 100); check(true, "pty_resize! did not throw")
    W.pty_close!(pty);            check(true, "pty_close! did not throw")
catch e
    println("  EXCEPTION: ", sprint(showerror, e))
    push!(fails, "powershell interactive test threw")
end

println("\n== Test 3: exact banner path _spawn_workspace_shell builds (base64 -Command) ==")
try
    banner = "\e[1mBANNER_MARKER\e[0m\r\n"
    b64 = Base64.base64encode(banner)
    setup = "\$b=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$(b64)')); [Console]::Write(\$b)"
    exe = ps_exe()
    pty = W.pty_spawn([exe, "-NoLogo", "-NoExit", "-Command", setup]; dir = "C:\\")
    out = drain(pty; timeout = 15, want = "BANNER_MARKER")
    println("  ", length(out), " bytes: ", repr(String(copy(out))))
    check(occursin("BANNER_MARKER", String(out)), "base64 -Command banner rendered")
    W.pty_close!(pty)
catch e
    println("  EXCEPTION: ", sprint(showerror, e))
    push!(fails, "banner path threw")
end

println("\n", isempty(fails) ? "ALL CONPTY TESTS PASSED ✅" : "FAILURES ($(length(fails))) ❌:")
foreach(f -> println("  - ", f), fails)
exit(isempty(fails) ? 0 : 1)
