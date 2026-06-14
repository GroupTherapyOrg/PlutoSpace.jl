# cli.jl — the `plutoland` command (a proper Julia app via Pkg.Apps).
#
# Install:  julia> import Pkg; Pkg.Apps.add(url="https://github.com/GroupTherapyOrg/PlutoLand.jl")
# Then:     $ plutoland                     # workspace opener (pick a folder)
#           $ plutoland .                   # current folder as workspace
#           $ plutoland ~/project           # that folder as workspace
#           $ plutoland notebook.jl         # open one notebook
#           $ plutoland --autorun …         # classic Pluto reactivity instead of lazy
#           $ plutoland --port 1234 …
#           $ plutoland --no-browser …

function (@main)(args)
    args = filter(a -> a != "--", collect(String, args))

    if "--help" in args || "-h" in args
        println("""
        PlutoLand 🟢🟣🔴 — a workspace for Pluto.jl notebooks, for humans and agents together.

        Usage:
          plutoland                    open the workspace picker in your browser
          plutoland <folder>           open a folder as the workspace
          plutoland <notebook.jl>      open a single notebook
          plutoland --port <n>         pick a port
          plutoland --autorun          classic Pluto reactivity (default is lazy/collab mode)
          plutoland --no-browser       don't open the browser
          plutoland --agents-md        seed the workspace's AGENTS.md/CLAUDE.md so coding agents
                                       discover the pluto-collab workflow (managed, idempotent block)

        In lazy mode (the default), file edits — yours or an agent's — mark cells stale
        instead of running them; outputs are cached in <notebook>.jl.pluto-cache.toml and
        survive restarts. The `pluto-collab` CLI is installed on your PATH next to `plutoland`,
        and any terminal opened inside PlutoLand exports PLUTOLAND_PORT / PLUTOLAND_SECRET so a
        coding agent's `pluto-collab` targets this live session automatically.
        """)
        return 0
    end

    user_cwd = pwd() # Pkg.Apps shims may change cwd before invoking julia

    port = nothing
    on_code_change = "lazy"
    launch_browser = true
    target = nothing

    i = 1
    while i <= length(args)
        a = args[i]
        if a == "--port"
            i += 1
            i <= length(args) || (println("--port needs a number"); return 1)
            port = tryparse(Int, args[i])
            port === nothing && (println("--port needs a number"); return 1)
        elseif a == "--autorun"
            on_code_change = "autorun"
        elseif a == "--no-browser"
            launch_browser = false
        elseif a == "--agents-md"
            ENV["PLUTOLAND_AGENTS_MD"] = "1"
        elseif startswith(a, "-")
            println("unknown option: $a (see --help)")
            return 1
        else
            target = a
        end
        i += 1
    end

    workspace = nothing
    notebook = nothing
    if target !== nothing
        resolved = isabspath(target) ? target : normpath(joinpath(user_cwd, target))
        if isdir(resolved)
            workspace = resolved
        elseif isfile(resolved)
            notebook = resolved
        else
            println("no such file or folder: $resolved")
            return 1
        end
    end

    run(; on_code_change, launch_browser,
        (port === nothing ? () : (port=port,))...,
        (workspace === nothing ? () : (workspace=workspace,))...,
        (notebook === nothing ? () : (notebook=notebook,))...)
    return 0
end
