// E2E test for the PlutoSpace /terminal websocket protocol (attach meta → replay → marker,
// resize semantics, shell-exit teardown). Drives a REAL server + REAL shell — start one first:
//
//   julia --project=. -e 'import PlutoSpace; PlutoSpace.run(port=7799, launch_browser=false)'
//   PLUTO_SECRET=<secret> node test/terminal_e2e.mjs 7799
//
// The secret is in the launch URL the server prints, or in its connection file:
//   ~/.local/state/pluto/servers/<host>-<port>.json
// Needs node ≥22 (global WebSocket). Unix only (asserts via stty).
const PORT = process.argv[2] ?? "7799"
const SECRET = process.env.PLUTO_SECRET ?? ""
if (!SECRET) {
    console.error("set PLUTO_SECRET (see the server's launch URL or its connection file)")
    process.exit(2)
}
const URL_BASE = `ws://127.0.0.1:${PORT}/terminal`

const fails = []
const check = (cond, msg) => {
    console.log((cond ? "  PASS  " : "  FAIL  ") + msg)
    if (!cond) fails.push(msg)
}

// One websocket session: collects text frames (protocol) and binary frames (shell output) separately.
const connect = (query) =>
    new Promise((resolve, reject) => {
        const ws = new WebSocket(`${URL_BASE}?${query}&secret=${SECRET}`)
        ws.binaryType = "arraybuffer"
        const s = { ws, texts: [], bytes: [], output: () => Buffer.concat(s.bytes).toString("utf8") }
        ws.onmessage = (e) => {
            if (typeof e.data === "string") s.texts.push(e.data)
            else s.bytes.push(Buffer.from(e.data))
        }
        ws.onopen = () => resolve(s)
        ws.onerror = (e) => reject(new Error("ws error: " + (e.message ?? "?")))
    })

const until = async (pred, timeout = 12000) => {
    const t0 = Date.now()
    while (Date.now() - t0 < timeout) {
        if (pred()) return true
        await new Promise((r) => setTimeout(r, 50))
    }
    return false
}

console.log("== 1: fresh attach — meta carries the URL geometry, replayed marker arrives ==")
const a = await connect("tid=e2e-test&rows=24&cols=80")
await until(() => a.texts.length >= 2)
console.log("  text frames:", JSON.stringify(a.texts))
const meta1 = JSON.parse(a.texts[0] ?? "{}")
check(meta1.rows === 24 && meta1.cols === 80, `first text frame is pty geometry 24x80 (got ${a.texts[0]})`)
check(a.texts.some((t) => JSON.parse(t).replayed === true), "replay-complete marker arrived")

console.log("== 2: the shell is real and at the URL size ==")
await until(() => a.output().length > 0)
a.ws.send("0:stty size\r")
check(await until(() => /24 80/.test(a.output())), "stty reports 24 80 (shell born at URL size)")

console.log("== 3: resize applies; same-size resize is a no-op ==")
a.ws.send("1:40,120")
a.ws.send("0:stty size\r")
check(await until(() => /40 120/.test(a.output())), "stty reports 40 120 after resize frame")
a.ws.send("1:40,120") // same size — must not disturb anything
a.ws.send("0:echo marker_$((6*7))\r")
check(await until(() => /marker_42/.test(a.output())), "shell still healthy after same-size resize")

console.log("== 4: reattach — meta reports the pty's CURRENT size (not the new URL's), replay has history ==")
a.ws.close()
await new Promise((r) => setTimeout(r, 300))
const b = await connect("tid=e2e-test&rows=50&cols=90") // URL size must be ignored for an existing shell
await until(() => b.texts.length >= 2)
console.log("  text frames:", JSON.stringify(b.texts))
const meta2 = JSON.parse(b.texts[0] ?? "{}")
check(meta2.rows === 40 && meta2.cols === 120, `reattach meta is the live pty size 40x120 (got ${b.texts[0]})`)
check(await until(() => /marker_42/.test(b.output())), "replayed scrollback contains earlier session output")
const marker_index = b.texts.findIndex((t) => JSON.parse(t).replayed === true)
check(marker_index >= 0, "reattach also got the replay-complete marker")

console.log("== 5: shell exit tears the session down ==")
b.ws.send("0:exit\r")
const closed = await until(() => b.ws.readyState === WebSocket.CLOSED, 8000)
check(closed, "socket closed after the shell exited")
check(/shell exited/.test(b.output()), "client was told the shell exited")

console.log("== 6: explicit tab-close reaps the server shell (no orphan); detach keeps it ==")
// A fresh tid: connect, then just close the socket (a DETACH — hide/dock/reload). The shell must
// survive: reconnecting replays scrollback.
const d1 = await connect("tid=e2e-close&rows=24&cols=80")
await until(() => d1.texts.some((t) => JSON.parse(t).replayed === true))
d1.ws.send("0:echo detach_marker_$((1+1))\r")
check(await until(() => /detach_marker_2/.test(d1.output())), "shell echoed before detach")
d1.ws.close()
await new Promise((r) => setTimeout(r, 300))
const d2 = await connect("tid=e2e-close&rows=24&cols=80")
check(await until(() => /detach_marker_2/.test(d2.output())), "detach preserved the shell (scrollback replays)")
// Now an explicit close via the API must reap it: a subsequent connect gets a FRESH shell (no marker).
const closeResp = await fetch(`http://127.0.0.1:${PORT}/api/v1/terminal/close?tid=e2e-close&secret=${SECRET}`, {
    method: "POST",
    headers: { Origin: `http://127.0.0.1:${PORT}` },
})
check(closeResp.status === 200, `POST /api/v1/terminal/close returned 200 (got ${closeResp.status})`)
d2.ws.close()
await new Promise((r) => setTimeout(r, 400))
const d3 = await connect("tid=e2e-close&rows=24&cols=80")
await until(() => d3.texts.some((t) => JSON.parse(t).replayed === true))
check(!/detach_marker_2/.test(d3.output()), "after tab-close the shell was reaped (fresh shell, no old scrollback)")

console.log(fails.length === 0 ? "\nALL TERMINAL E2E TESTS PASSED" : `\nFAILURES (${fails.length}):\n` + fails.map((f) => "  - " + f).join("\n"))
process.exit(fails.length === 0 ? 0 : 1)
