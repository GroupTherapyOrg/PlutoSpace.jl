<div align="center">

<img src="frontend/img/plutoland.svg" width="110" alt="PlutoLand">

# PlutoLand.jl

### A workspace for Pluto notebooks — built for humans and agents, together.

</div>

Open a **folder** as your workspace. Notebooks open as **tabs** — each one the unmodified
[Pluto.jl](https://github.com/fonsp/Pluto.jl) editor. A real **terminal** runs alongside.
And any coding agent in any terminal can work in the same live session: its file edits show
up as stale cells in your browser within a second, runs execute exactly what changed and
nothing more, and all outputs survive restarts.

## Install & run

```julia
julia> import Pkg; Pkg.Apps.add(url="https://github.com/GroupTherapyOrg/PlutoLand.jl")
```

```sh
$ plutoland               # workspace picker
$ plutoland ~/project     # open a folder as workspace
$ plutoland --help
```

Or as a package: `PlutoLand.run()` (every `Pluto.run` keyword works).

## What you get

- **Folder workspaces** — file tree, notebooks and plain files as tabs, SSH remote
  workspaces (point-and-click, VS Code style), an integrated terminal that survives
  page refreshes.
- **Lazy collab mode** (the default) — edits, from the browser *or* the filesystem, mark
  cells stale instead of running them. You (or your agent) run exactly the stale set.
  Cell outputs are cached in a `<notebook>.jl.pluto-cache.toml` sidecar and restored on
  reopen, verified by content-addressed execution keys.
- **An agent surface made of boring plumbing** — a connection file in
  `~/.local/state/pluto/servers/`, a plain HTTP API (`/api/v1/…`), and the
  [`bin/pluto-collab`](bin/pluto-collab) CLI (curl + sed, nothing else). No MCP, no
  plugins: any tool that can edit files and run shell commands already works.
  See [COLLAB.md](COLLAB.md) for the full story and an AGENTS.md stanza.

`--autorun` gives you classic Pluto reactivity whenever you want it.

## Relationship to Pluto.jl

PlutoLand is a friendly fork of [Pluto.jl](https://github.com/fonsp/Pluto.jl) — the
notebook engine, editor, file format, and reactivity are Pluto's, and notebooks remain
fully compatible in both directions. For everything about notebooks themselves
(reactivity, `@bind`, packages, exporting), see the
[Pluto documentation](https://plutojl.org/). 🎈

PlutoLand adds the *land around* the notebooks: workspaces, tabs, terminal, remotes,
persistence, and first-class human+agent collaboration.

## License

MIT — see [LICENSE](LICENSE). Pluto.jl is by Fons van der Plas and contributors.
