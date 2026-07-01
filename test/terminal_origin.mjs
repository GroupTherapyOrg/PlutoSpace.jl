// Security regression test for the same-origin gate on the /terminal WebSocket and the
// state-changing HTTP API. Proves the cross-site-WebSocket-hijack / same-site-CSRF → RCE holes
// are closed WITHOUT breaking legitimate same-origin or non-browser (no-Origin) clients.
//
//   julia --project=. -e 'import PlutoSpace; PlutoSpace.run(port=7799, launch_browser=false)'
//   PLUTO_SECRET=<secret> node test/terminal_origin.mjs 7799
//
// Needs node ≥22 (global WebSocket + fetch). The undici WebSocket client sends NO Origin header,
// which is exactly a non-browser client — so it stands in for the CLI/curl case that must pass.
const PORT = process.argv[2] ?? "7799"
const SECRET = process.env.PLUTO_SECRET ?? ""
if (!SECRET) {
    console.error("set PLUTO_SECRET")
    process.exit(2)
}
const HOST = `127.0.0.1:${PORT}`
const fails = []
const check = (cond, msg) => {
    console.log((cond ? "  PASS  " : "  FAIL  ") + msg)
    if (!cond) fails.push(msg)
}

// Connect with an explicit Origin header (undici lets us set it via the options bag). Resolves
// {opened:bool}: whether the handshake completed.
const tryWs = (query, headers) =>
    new Promise((resolve) => {
        const ws = new WebSocket(`ws://${HOST}/terminal?${query}&secret=${SECRET}`, { headers })
        let settled = false
        const done = (opened) => {
            if (settled) return
            settled = true
            try {
                ws.close()
            } catch {}
            resolve({ opened })
        }
        ws.onopen = () => done(true)
        ws.onerror = () => done(false)
        setTimeout(() => done(false), 5000)
    })

console.log("== A: matching Origin is accepted (legit same-origin browser) ==")
const a = await tryWs("tid=orig-ok", { Origin: `http://${HOST}` })
check(a.opened, "WS with Origin == Host opened")

console.log("== B: no Origin is accepted (CLI / curl / native client) ==")
const b = await tryWs("tid=orig-none", {})
check(b.opened, "WS with no Origin opened")

console.log("== C: cross-origin (another localhost port) is REJECTED — the CSWSH→RCE hole ==")
const c = await tryWs("tid=orig-evil", { Origin: "http://127.0.0.1:65000" })
check(!c.opened, "WS from a different-port Origin was refused")

console.log("== D: foreign-host Origin is REJECTED ==")
const d = await tryWs("tid=orig-evil2", { Origin: "http://evil.example.com" })
check(!d.opened, "WS from a foreign Origin was refused")

console.log("== E: state-changing POST with cross-origin Origin is REJECTED (CSRF file-write) ==")
const evilPost = await fetch(`http://${HOST}/api/v1/file/save?path=/tmp/plutospace_csrf_probe.txt&secret=${SECRET}`, {
    method: "POST",
    headers: { Origin: "http://127.0.0.1:65000", "Content-Type": "text/plain" },
    body: "pwned",
})
check(evilPost.status === 403, `cross-origin POST /api/v1/file/save blocked (got ${evilPost.status})`)

console.log("== F: same-origin POST still works (legit save path) ==")
const okPost = await fetch(`http://${HOST}/api/v1/file/save?path=/tmp/plutospace_ok_probe.txt&secret=${SECRET}`, {
    method: "POST",
    headers: { Origin: `http://${HOST}`, "Content-Type": "text/plain" },
    body: "hello",
})
check(okPost.status >= 200 && okPost.status < 300, `same-origin POST /api/v1/file/save accepted (got ${okPost.status})`)

console.log(fails.length === 0 ? "\nALL ORIGIN-GATE TESTS PASSED" : `\nFAILURES (${fails.length}):\n` + fails.map((f) => "  - " + f).join("\n"))
process.exit(fails.length === 0 ? 0 : 1)
