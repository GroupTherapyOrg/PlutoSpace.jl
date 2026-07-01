#!/usr/bin/env bash
# Regression test for the edit-then-run clobber race (collab audit HIGH-1).
#
# The documented agent workflow is "edit the .jl, then `pluto-collab run --stale`". The background
# file watcher only syncs the in-memory notebook after a ~0.4s debounce, so an edit-then-IMMEDIATELY
# -run used to race it: the server ran the OLD in-memory cells and (because the run also saves) wrote
# them straight back over the just-written file — silently losing the edit. serve_api_run now syncs
# from disk BEFORE choosing the stale set, closing the window.
#
# This mirrors collab_acceptance.sh but DELIBERATELY OMITS the sleep between the edit and the run —
# that sleep is exactly what masked this bug in the acceptance test.
#
# Usage: bash test/collab_run_race.sh    (needs julia --project=this, curl, sed)

set -u
cd "$(dirname "$0")/.."
REPO=$(pwd)
CLI="$REPO/bin/pluto-collab"
PORT=7998
WORKDIR=$(mktemp -d)
NB="$WORKDIR/race_notebook.jl"
MARK="$WORKDIR/executed_marker.txt"   # the running cell writes here, so we see which CODE actually ran
SERVER_LOG="$WORKDIR/server.log"
PASS=0
FAIL=0

check() {
    desc=$1; shift
    if "$@" >/dev/null 2>&1; then PASS=$((PASS+1)); echo "ok: $desc"; else FAIL=$((FAIL+1)); echo "FAIL: $desc" >&2; fi
}
cleanup() { [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null; sleep 1; rm -rf "$WORKDIR"; }
trap cleanup EXIT

# One cell that records which version executed by writing a marker file, plus returning the tag.
write_nb() { # write_nb <TAG>
    cat > "$WORKDIR/nb.tmp" <<EOF
### A Pluto.jl notebook ###
# v0.20.21

using Markdown
using InteractiveUtils

# ╔═╡ 11111111-1111-1111-1111-111111111111
begin
    write(raw"$MARK", "$1")
    tag = "$1"
end

# ╔═╡ Cell order:
# ╠═11111111-1111-1111-1111-111111111111
EOF
    mv "$WORKDIR/nb.tmp" "$NB"   # atomic, agent-style
}

write_nb V1

julia --project="$REPO" -e "
    import PlutoSpace
    PlutoSpace.run(port=$PORT, launch_browser=false, require_secret_for_open_links=true,
                   on_code_change=\"lazy\", workspace_use_distributed=false, notebook=\"$NB\")" >>"$SERVER_LOG" 2>&1 &
SERVER_PID=$!

echo "--- waiting for the server to open the notebook"
opened=1
for _ in $(seq 1 150); do
    if "$CLI" notebooks 2>/dev/null | grep -qF "$NB"; then opened=0; break; fi
    sleep 1
done
check "server opened the notebook" test "$opened" = 0

echo "--- baseline: run V1 so the notebook is live and in-memory"
"$CLI" run "$NB" --stale >/dev/null 2>&1
check "V1 executed at baseline (marker = V1)" sh -c "grep -qx V1 '$MARK'"

echo "--- THE RACE: write V2 atomically, then run --stale with NO sleep"
write_nb V2
"$CLI" run "$NB" --stale >/dev/null 2>&1

# The new code must have executed, and the file must NOT have been clobbered back to V1.
check "the NEW code executed (marker = V2, not V1)" sh -c "grep -qx V2 '$MARK'"
check "the .jl on disk is still V2 (not overwritten with V1)" grep -q '"V2"' "$NB"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ] && echo "COLLAB RUN-RACE TEST PASSED" || echo "COLLAB RUN-RACE TEST FAILED"
exit "$FAIL"
