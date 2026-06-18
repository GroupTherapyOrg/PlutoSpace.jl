# PlutoSpace collaboration: humans and agents on one live notebook

PlutoSpace's **lazy reactive mode** (the default): a human in the browser and any number of
external tools (coding agents, scripts, CI) work on the **same live notebook session** —
same kernel, same state, both sides see everything in real time — using nothing but
**files, plain HTTP, and a tiny CLI**. No MCP servers, no plugins, no agent integrations:
any tool that can edit a file and run `curl` already works.

## Start

```julia
import PlutoSpace
PlutoSpace.run()        # lazy collab mode is the default
```

(or `plutospace` from a terminal, once installed as an app). Lazy mode means three things:

1. **Edits mark cells stale instead of running them.** When the notebook `.jl` file changes
   on disk (lazy mode watches it automatically), the edited cells get the familiar yellow
   *modified* marker in the browser — the exact same look as typing in a cell yourself —
   within about a second, and **nothing executes**. A "N cells are stale (RUN)" notice
   appears; click it (or run any cell) when *you* decide. Exactly like normal Pluto: running
   a cell re-runs its dependents reactively, and *other* cells' pending changes are never
   dragged in — they apply only when their own cells run (one by one, or all at once with
   Ctrl+S). The one exception is workspace-cold cells restored from cache after a restart:
   those are pulled in automatically when needed, because their values don't exist in the
   kernel yet.

2. **Outputs survive restarts.** After every run, outputs and execution keys are written to
   `<notebook>.jl.pluto-cache.toml` — a plain-TOML, deletable cache sidecar. Reopening the
   notebook restores every output whose code (and upstream results) are unchanged, instantly,
   without running anything. Cells edited while the server was off show up stale.
   The sidecar doubles as a *machine-readable view of all outputs*: any tool can read
   results by reading that file. (Add `*.pluto-cache.toml` to `.gitignore`.)

3. **A live HTTP API + CLI.** Every running server writes a connection file to
   `~/.local/state/pluto/servers/<node>-<port>.json` (port + access secret — the Jupyter
   connection-file idiom; the `<node>` prefix keeps servers on a shared `$HOME`, one per
   HPC compute node, from colliding). The `bin/pluto-collab` CLI uses it to find your server:

   ```
   pluto-collab status notebook.jl            # per-cell: stale / cold / errored / output
   pluto-collab run notebook.jl --stale       # run all stale cells; blocks; exit 1 on error
   pluto-collab run notebook.jl --cell <id>   # run one cell (+ its stale/cold ancestors)
   pluto-collab interrupt notebook.jl         # stop a running notebook
   pluto-collab restart notebook.jl           # restart kernel + re-run all — recover a dead worker
   pluto-collab status notebook.jl --json     # same, structured
   ```

   Runs requested over HTTP go through the same execution queue as browser runs — you watch
   the agent's cells turn amber → running → green live in your browser, and vice versa.

## Staleness is verified, not guessed

Each cell records an **execution key**: a hash of its own code plus the *result hashes* of
the cells it depends on (a verifying trace, as in build systems). Stale marks are checked
against these keys, so:

- **Reverting an edit un-stales everything** — no runs needed.
- **Early cutoff**: if a cell re-runs but produces the same result, its dependents are
  un-marked automatically.
- **Restart verification**: cached outputs are only trusted when the keys prove that code
  and upstream results are unchanged.

Impure cells (`rand()`, time, I/O) can opt out with cell metadata `always_stale = true`
(in the file: a `# ╠═╡ always_stale = true` line) — their cached outputs are never trusted.

A restored notebook's cells are **workspace-cold**: the display is current, but the kernel
hasn't computed them in this process. Cold cells are pulled in exactly like stale ones the
first time something downstream runs (including bond/slider updates), so the session heals
itself on demand.

## The agent workflow (any agent, any terminal)

```text
1. (human)  plutospace nb.jl
2. (agent)  edits nb.jl with its normal file tools         ← human sees cells go stale, live
3. (agent)  pluto-collab status nb.jl                      ← sees exactly what's stale
4. (agent)  pluto-collab run nb.jl --stale                 ← human watches cells run, live
5. (agent)  reads outputs from the run response, status, or nb.jl.pluto-cache.toml
```

Expensive unrelated cells are never re-run: only the stale closure executes.

### Unattended / overnight loops (recovering a dead worker)

A notebook's worker can die mid-run — out-of-memory, a segfault in native code (CUDA/BLAS),
an explicit `exit()`. The editor then shows **"Process exited — restart"** and Pluto raises
`Malt.TerminatedWorkerException`. At that point `interrupt` is useless (nothing is running) and
`run` has no live process to run into — an unattended agent must **restart**:

```
pluto-collab restart nb.jl     # fresh kernel, re-runs the whole notebook; blocks; exit 1 on error
```

`restart` re-runs *everything*, so reserve it for an actual crash — on a plain cell error, fix the
cell and `run` again instead. A self-healing "run all night" loop is then:

```bash
while :; do
  pluto-collab run nb.jl --stale && { sleep 60; continue; }   # clean → wait, go again
  # run failed; if the worker is gone (not just a cell error) bring it back, then keep looping
  pluto-collab status nb.jl | grep -q 'process: no_process' && pluto-collab restart nb.jl
  sleep 60
done
```

### AGENTS.md stanza

Drop this in any notebook repo so agents discover the workflow (works for Claude Code's
CLAUDE.md too):

```markdown
## Pluto notebooks (live collaborative sessions)

Notebooks (`*.jl` with Pluto cell markers) may be OPEN in a live lazy-mode Pluto server.
- Edit notebook files directly with your file tools. Edits only mark cells stale — nothing
  runs until requested, and the human sees staleness live in their browser.
- `pluto-collab status <nb.jl>` shows per-cell state and outputs.
- `pluto-collab run <nb.jl> --stale` runs exactly what's outdated (blocking; exit 1 if a
  cell errors). Never re-run the whole notebook.
- `pluto-collab restart <nb.jl>` restarts the kernel and re-runs everything — use it ONLY to
  recover a dead/exited worker ("Process exited" / `TerminatedWorkerException`), which interrupt
  and run cannot revive.
- All cell outputs are also in `<nb.jl>.pluto-cache.toml` (plain TOML; a deletable cache).
- Cell ids are the UUIDs in `# ╔═╡ <uuid>` markers. Keep the `# ╔═╡ Cell order:` section
  in sync when adding/removing cells.
```

## Compatibility

- `--autorun` / `on_code_change="autorun"` is byte-for-byte vanilla Pluto behavior.
- Notebook files stay fully compatible with upstream Pluto in both directions.
- The sidecar and connection files are pure caches/metadata — safe to delete at any time.

## End-to-end test

```
bash test/collab_acceptance.sh
```
