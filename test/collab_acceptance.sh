#!/usr/bin/env bash
# End-to-end acceptance test for the collab fork:
# a real Pluto server + the pluto-collab CLI + agent-style external file edits.
#
# Usage: bash test/collab_acceptance.sh
# Needs: julia (with this Pluto checked out as --project), curl, sed.

set -u
cd "$(dirname "$0")/.."
REPO=$(pwd)
CLI="$REPO/bin/pluto-collab"
PORT=7997
WORKDIR=$(mktemp -d)
NB="$WORKDIR/acceptance_notebook.jl"
SERVER_LOG="$WORKDIR/server.log"
PASS=0
FAIL=0

check() { # check <description> <command...>
    desc=$1; shift
    if "$@" >/dev/null 2>&1; then
        PASS=$((PASS+1)); echo "ok: $desc"
    else
        FAIL=$((FAIL+1)); echo "FAIL: $desc" >&2
    fi
}

cleanup() {
    [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null
    [ -n "${SERVER_PID2:-}" ] && kill "$SERVER_PID2" 2>/dev/null
    sleep 1
    rm -rf "$WORKDIR"
}
trap cleanup EXIT

# --- a tiny Pluto notebook: a → b → c chain ---
cat > "$NB" <<'EOF'
### A Pluto.jl notebook ###
# v0.20.21

using Markdown
using InteractiveUtils

# ╔═╡ 11111111-1111-1111-1111-111111111111
a = 1

# ╔═╡ 22222222-2222-2222-2222-222222222222
b = a + 1

# ╔═╡ 33333333-3333-3333-3333-333333333333
c = b * 10

# ╔═╡ Cell order:
# ╠═11111111-1111-1111-1111-111111111111
# ╠═22222222-2222-2222-2222-222222222222
# ╠═33333333-3333-3333-3333-333333333333
EOF

start_server() {
    julia --project="$REPO" -e "
        import PlutoLand
        PlutoLand.run(
            port=$PORT,
            launch_browser=false,
            require_secret_for_open_links=true,
            on_code_change=\"lazy\",
            workspace_use_distributed=false,
            notebook=\"$NB\",
        )" >>"$SERVER_LOG" 2>&1 &
}

wait_for_notebook() {
    for _ in $(seq 1 120); do
        if "$CLI" notebooks 2>/dev/null | grep -qF "$NB"; then return 0; fi
        sleep 1
    done
    return 1
}

echo "--- starting server (log: $SERVER_LOG)"
start_server; SERVER_PID=$!
check "server opens the notebook (discovered via connection file)" wait_for_notebook

echo "--- 1. open in lazy mode: nothing ran, all cells stale"
check "status reports 3 stale cells" sh -c "'$CLI' status '$NB' | grep -q '3 stale'"

echo "--- 2. run all stale cells via CLI"
check "run --stale exits 0" "$CLI" run "$NB" --stale
check "outputs are correct (c = 20)" sh -c "'$CLI' status '$NB' | grep -q 'output: 20'"
check "nothing stale afterwards" sh -c "'$CLI' status '$NB' | grep -q '0 stale'"
check "sidecar cache file written" test -f "$NB.pluto-cache.toml"
check "sidecar contains the output text" grep -q '"20"' "$NB.pluto-cache.toml"

echo "--- 3. agent-style external edit (atomic temp+rename): the edited cell goes stale"
sed 's/a = 1/a = 2/' "$NB" > "$NB.tmp" && mv "$NB.tmp" "$NB"
sleep 3
check "exactly the edited cell is stale, nothing ran" sh -c "'$CLI' status '$NB' | grep -q '1 stale'"
check "old output still displayed" sh -c "'$CLI' status '$NB' | grep -q 'output: 20'"

echo "--- 4. run the stale cell; dependents re-run reactively"
check "run --stale exits 0" "$CLI" run "$NB" --stale
check "new outputs (c = 30)" sh -c "'$CLI' status '$NB' | grep -q 'output: 30'"

echo "--- 5. error propagation: exit code 1 + stacktrace in output"
sed 's/b = a + 1/b = error("boom")/' "$NB" > "$NB.tmp" && mv "$NB.tmp" "$NB"
sleep 3
"$CLI" run "$NB" --stale >/dev/null 2>&1
rc=$?
check "run with an erroring cell exits 1 (got $rc)" test "$rc" = 1
check "error message visible in status" sh -c "'$CLI' status '$NB' | grep -qi 'boom'"

echo "--- 6. fix the error; pending changes do NOT propagate through other cells' runs"
sed 's/b = error("boom")/b = a + 5/' "$NB" > "$NB.tmp" && mv "$NB.tmp" "$NB"
sleep 3
"$CLI" run "$NB" --cell 33333333-3333-3333-3333-333333333333 >/dev/null 2>&1
rc=$?
check "running c alone does not pull in b's pending fix (still errors, got $rc)" test "$rc" = 1
check "b's fix is still pending (stale)" sh -c "'$CLI' status '$NB' | grep -q '1 stale'"
check "run --stale applies the fix (b runs, c follows reactively)" "$CLI" run "$NB" --stale
check "c recomputed (c = 70)" sh -c "'$CLI' status '$NB' | grep -q 'output: 70'"

echo "--- 7. restart: outputs survive via the sidecar, nothing re-runs"
kill "$SERVER_PID" 2>/dev/null; SERVER_PID=""
sleep 2
start_server; SERVER_PID2=$!
check "server restarted with notebook" wait_for_notebook
check "outputs restored from cache (c = 70)" sh -c "'$CLI' status '$NB' | grep -q 'output: 70'"
check "no stale cells after restore (keys verified)" sh -c "'$CLI' status '$NB' | grep -q '0 stale'"
check "cells are workspace-cold" sh -c "'$CLI' status '$NB' | grep -q 'COLD'"

echo "--- 8. JSON output for agents"
check "status --json has stale field" sh -c "'$CLI' status '$NB' --json | grep -q '\"stale\":'"

echo
echo "=== acceptance: $PASS passed, $FAIL failed ==="
[ "$FAIL" = 0 ]
