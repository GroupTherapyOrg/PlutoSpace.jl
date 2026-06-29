###
# The collab HTTP API: how external tools (coding agents, scripts, CI) talk to a LIVE PlutoSpace server.
#
# Design constraints (deliberate):
#  - Plain HTTP + the existing Pluto secret for auth (`?secret=...` or cookie) — curl-able from
#    any terminal, no protocol stack, no registration. Works for any tool that can run curl.
#  - Input via query parameters, output as JSON (`format=json`, default) or plain text
#    (`format=text`) — so a thin shell client needs no JSON parser at all.
#  - Server discovery via a connection file (like Jupyter's kernel-*.json): every running server
#    writes `$XDG_STATE_HOME/pluto/servers/<node>-<port>.json` with its port and secret (the <node>
#    prefix keeps servers on a shared $HOME — one per HPC node — from colliding; see collab_registry_path).
#  - Runs are BLOCKING: the HTTP response is held open until the cells finish, so a client gets
#    success/failure from one request. Runs go through the same execution path (and the same
#    execution token) as browser clients — both sides see each other's runs live.
###

# --- a minimal JSON writer (Pluto has no JSON dependency; output only, no parsing needed) ---

function _json_string(s::AbstractString)
    io = IOBuffer()
    print(io, '"')
    for c in s
        if c == '"'
            print(io, "\\\"")
        elseif c == '\\'
            print(io, "\\\\")
        elseif c == '\n'
            print(io, "\\n")
        elseif c == '\r'
            print(io, "\\r")
        elseif c == '\t'
            print(io, "\\t")
        elseif UInt32(c) < 0x20
            print(io, "\\u", string(UInt32(c), base=16, pad=4))
        else
            print(io, c)
        end
    end
    print(io, '"')
    String(take!(io))
end

_json(x::AbstractString) = _json_string(x)
_json(x::Bool) = x ? "true" : "false"
_json(x::Integer) = string(x)
_json(x::Real) = isfinite(x) ? string(x) : "null"
_json(::Nothing) = "null"
_json(x::AbstractVector) = "[" * join((_json(v) for v in x), ",") * "]"
_json(x::Vector{<:Pair}) = "{" * join(("$(_json_string(String(first(p)))):$(_json(last(p)))" for p in x), ",") * "}"

# --- server connection registry (Jupyter kernel-<id>.json idiom) ---

collab_registry_dir() = joinpath(get(ENV, "XDG_STATE_HOME", joinpath(homedir(), ".local", "state")), "pluto", "servers")

# Tag the registry filename with the node's hostname: "<node>-<port>.json".
# On a shared $HOME (an HPC cluster mounts the same NFS home on every compute node) this one
# directory is shared by every node's PlutoSpace server. A bare "<port>.json" name collides across
# nodes — each node's server independently grabs the same default port (1234), so the second writer
# silently clobbers the first, and discovery/cleanup can't tell whose file is whose. The hostname
# prefix gives each node its own filenames; on a single local machine it's just a constant prefix.
# (Hostnames are filename-safe in practice; sanitize defensively. Readers glob "$(hostname)-*.json"
# on the SAME node, and Julia's gethostname() == the shell's `hostname` — same syscall — so they match.)
_registry_node() = replace(gethostname(), r"[^A-Za-z0-9._-]" => "_")
collab_registry_path(port::Integer) = joinpath(collab_registry_dir(), "$(_registry_node())-$(port).json")

"Write the connection file that lets external tools discover this live server (port + secret). Flat JSON, greppable with sed — clients need no JSON parser."
function write_collab_registry_file(session::ServerSession, port::Integer)
    dir = collab_registry_dir()
    mkpath(dir)
    path = collab_registry_path(port)
    ws = session.options.server.workspace_folder
    write(path, """{"pid": $(getpid()), "host": $(_json_string(session.options.server.host)), "port": $(port), "node": $(_json_string(gethostname())), "secret": $(_json_string(session.secret)), "workspace": $(ws === nothing ? "null" : _json_string(tamepath(ws))), "pluto_version": $(_json_string(PLUTO_VERSION_STR)), "started_at": $(time())}\n""")
    try
        chmod(path, 0o600) # the file contains the access secret
    catch end
    path
end

function remove_collab_registry_file(port::Integer)
    path = collab_registry_path(port)
    try
        isfile(path) && rm(path)
    catch end
end

# --- the workspace tree (PlutoSpace) ---

"Does this file look like a Pluto notebook? (`.jl` extension + the Pluto header on line 1)"
function _is_pluto_notebook_file(path::String)::Bool
    endswith(path, ".jl") || return false
    try
        Base.open(io -> startswith(readline(io), _notebook_header), path, "r")
    catch
        false
    end
end

# Dotfiles ARE shown (you want to see .gitignore, .github/, env files…); we only skip the few
# entries that are pure noise or so large they'd blow the entry budget and bury real files.
const _WORKSPACE_SKIPLIST = ("node_modules", "frontend-dist", ".git", ".DS_Store")

"Recursive listing of a workspace folder as JSON-able pairs. Depth- and entry-budgeted; bulky tool directories (and .git) are skipped, but dotfiles are shown."
function _workspace_entries(dir::String; depth::Int=6, budget::Ref{Int}=Ref(2000))
    entries = Vector{Pair}[]
    isdir(dir) || return entries
    names = try
        sort(readdir(dir))
    catch
        return entries
    end
    # directories first, like every file browser
    for want_dir in (true, false), name in names
        budget[] <= 0 && break
        name ∈ _WORKSPACE_SKIPLIST && continue
        p = joinpath(dir, name)
        isdir(p) == want_dir || continue
        budget[] -= 1
        if want_dir
            push!(entries, Pair[
                "name" => name,
                "path" => p,
                "type" => "dir",
                "children" => depth <= 0 ? Vector{Pair}[] : _workspace_entries(p; depth=depth - 1, budget),
            ])
        else
            push!(entries, Pair[
                "name" => name,
                "path" => p,
                "type" => _is_pluto_notebook_file(p) ? "notebook" : "file",
            ])
        end
    end
    entries
end

# Walk up from `dir` to the repo's `.git` (a directory, or — for linked worktrees and
# submodules — a file holding "gitdir: <path>"), read its HEAD, and return the current
# branch. Reads the files directly: no `git` subprocess, no dependency on a git binary.
# → ("main", false) on a branch; ("a1b2c3d", true) on a detached HEAD; nothing if not a repo.
function _git_head_info(dir::String)
    git_path = nothing
    d = dir
    while true
        candidate = joinpath(d, ".git")
        if ispath(candidate)
            git_path = candidate
            break
        end
        parent = dirname(d)
        parent == d && break # reached the filesystem root
        d = parent
    end
    git_path === nothing && return nothing

    gitdir = if isdir(git_path)
        git_path
    else
        line = try
            strip(read(git_path, String))
        catch
            return nothing
        end
        startswith(line, "gitdir:") || return nothing
        p = strip(line[(ncodeunits("gitdir:") + 1):end])
        isabspath(p) ? p : normpath(joinpath(dirname(git_path), p))
    end

    head_file = joinpath(gitdir, "HEAD")
    isfile(head_file) || return nothing
    head = try
        strip(read(head_file, String))
    catch
        return nothing
    end
    if startswith(head, "ref:")
        ref = strip(replace(head, r"^ref:\s*" => ""))
        branch = replace(ref, r"^refs/heads/" => "")
        isempty(branch) ? nothing : (branch, false)
    else
        sha = first(head, 7) # detached HEAD: a raw commit sha
        isempty(sha) ? nothing : (sha, true)
    end
end

function _git_workspace_info(dir::String)::Union{Vector{Pair},Nothing}
    info = _git_head_info(dir)
    info === nothing && return nothing
    branch, detached = info
    Pair["branch" => branch, "detached" => detached]
end

# --- the API routes ---

function _api_cell_pairs(cell::Cell)::Vector{Pair}
    Pair[
        "cell_id" => string(cell.cell_id),
        "code" => cell.code,
        "stale" => cell.stale,
        "workspace_cold" => cell.workspace_cold,
        "queued" => cell.queued,
        "running" => cell.running,
        "errored" => cell.errored,
        "runtime_ns" => cell.runtime === nothing ? nothing : Int64(min(cell.runtime, typemax(Int64) % UInt64)),
        "mime" => string(cell.output.mime),
        "output_text" => _text_representation(cell),
        "execution_key" => string(cell.execution_key_produced, base=16),
    ]
end

function _api_cell_text_line(notebook::Notebook, i::Integer, cell::Cell)::String
    flags = String[]
    cell.stale && push!(flags, "STALE")
    cell.workspace_cold && push!(flags, "COLD")
    cell.running && push!(flags, "RUNNING")
    cell.queued && push!(flags, "QUEUED")
    cell.errored && push!(flags, "ERRORED")
    flag_str = isempty(flags) ? "fresh" : join(flags, ",")
    first_line = first(split(cell.code, '\n'; limit=2))
    out_first = first(split(_text_representation(cell), '\n'; limit=2))
    "[$i] $(cell.cell_id) $flag_str\n    code: $first_line\n    output: $out_first"
end

function _api_notebook_text(notebook::Notebook, session::ServerSession)::String
    n_stale = count(c -> c.stale, notebook.cells)
    n_cold = count(c -> c.workspace_cold, notebook.cells)
    header = """
    notebook: $(notebook.path)
    notebook_id: $(notebook.notebook_id)
    process: $(notebook.process_status)
    mode: $(is_lazy(session) ? "lazy" : "autorun")
    cells: $(length(notebook.cells)) ($(n_stale) stale, $(n_cold) cold)
    """
    body = join((_api_cell_text_line(notebook, i, c) for (i, c) in enumerate(notebook.cells)), "\n")
    header * "\n" * body * "\n"
end

function _api_notebook_json(notebook::Notebook, session::ServerSession)::String
    _json(Pair[
        "notebook_id" => string(notebook.notebook_id),
        "path" => notebook.path,
        "process_status" => notebook.process_status,
        "mode" => is_lazy(session) ? "lazy" : "autorun",
        "cells" => [_api_cell_pairs(c) for c in notebook.cells],
    ])
end

_api_wants_text(query) = get(query, "format", "json") == "text"

_api_error(status, msg, fmt_text) = HTTP.Response(status,
    ["Content-Type" => fmt_text ? "text/plain; charset=utf-8" : "application/json; charset=utf-8"],
    fmt_text ? "error: $msg\n" : _json(Pair["error" => msg]) * "\n")

"Find a notebook by `id` or by `path` (realpath comparison) from query parameters."
function _api_notebook_from_query(session::ServerSession, query)::Union{Notebook,Nothing}
    if haskey(query, "id")
        id = try
            UUID(query["id"])
        catch
            return nothing
        end
        return get(session.notebooks, id, nothing)
    elseif haskey(query, "path")
        requested = try
            realpath(query["path"])
        catch
            return nothing # path does not exist
        end
        for nb in values(session.notebooks)
            if isfile(nb.path) && realpath(nb.path) == requested
                return nb
            end
        end
    end
    nothing
end

function register_collab_api!(router, session::ServerSession)

    function serve_api_notebooks(request::HTTP.Request)
        query = HTTP.queryparams(HTTP.URI(request.target))
        if _api_wants_text(query)
            body = join(("$(id)\t$(nb.path)" for (id, nb) in session.notebooks), "\n")
            HTTP.Response(200, ["Content-Type" => "text/plain; charset=utf-8"], body * "\n")
        else
            body = _json([Pair["notebook_id" => string(id), "path" => nb.path] for (id, nb) in session.notebooks])
            HTTP.Response(200, ["Content-Type" => "application/json; charset=utf-8"], body * "\n")
        end
    end
    HTTP.register!(router, "GET", "/api/v1/notebooks", serve_api_notebooks)

    function serve_api_notebook(request::HTTP.Request)
        query = HTTP.queryparams(HTTP.URI(request.target))
        fmt_text = _api_wants_text(query)
        notebook = _api_notebook_from_query(session, query)
        notebook === nothing && return _api_error(404, "notebook not found — is it open in this server? (pass ?path=/abs/path.jl or ?id=<uuid>)", fmt_text)
        if fmt_text
            HTTP.Response(200, ["Content-Type" => "text/plain; charset=utf-8"], _api_notebook_text(notebook, session))
        else
            HTTP.Response(200, ["Content-Type" => "application/json; charset=utf-8"], _api_notebook_json(notebook, session) * "\n")
        end
    end
    HTTP.register!(router, "GET", "/api/v1/notebook", serve_api_notebook)

    # Read ONE cell's FULL output (the status digest caps each cell at 20k; this returns up to 200k
    # so an agent can pull a long result it saw truncated in `status`).
    function serve_api_cell(request::HTTP.Request)
        query = HTTP.queryparams(HTTP.URI(request.target))
        fmt_text = _api_wants_text(query)
        notebook = _api_notebook_from_query(session, query)
        notebook === nothing && return _api_error(404, "notebook not found — is it open in this server? (pass ?path=/abs/path.jl or ?id=<uuid>)", fmt_text)
        haskey(query, "cell") || return _api_error(400, "specify ?cell=<uuid>", fmt_text)
        cid = try
            UUID(strip(query["cell"]))
        catch
            return _api_error(400, "invalid cell id: $(query["cell"])", fmt_text)
        end
        haskey(notebook.cells_dict, cid) || return _api_error(404, "no cell with id $(query["cell"])", fmt_text)
        cell = notebook.cells_dict[cid]
        full = _text_representation(cell; limit=200_000)
        if fmt_text
            flags = String[]
            cell.stale && push!(flags, "STALE"); cell.workspace_cold && push!(flags, "COLD")
            cell.running && push!(flags, "RUNNING"); cell.queued && push!(flags, "QUEUED")
            cell.errored && push!(flags, "ERRORED")
            state = isempty(flags) ? "fresh" : join(flags, ",")
            body = "cell: $(cell.cell_id)\nstate: $(state)\nmime: $(cell.output.mime)\n\ncode:\n$(cell.code)\n\noutput:\n$(full)\n"
            HTTP.Response(200, ["Content-Type" => "text/plain; charset=utf-8"], body)
        else
            body = _json(Pair[
                "cell_id" => string(cell.cell_id),
                "code" => cell.code,
                "stale" => cell.stale, "workspace_cold" => cell.workspace_cold,
                "queued" => cell.queued, "running" => cell.running, "errored" => cell.errored,
                "mime" => string(cell.output.mime),
                "output_text" => full,
            ])
            HTTP.Response(200, ["Content-Type" => "application/json; charset=utf-8"], body * "\n")
        end
    end
    HTTP.register!(router, "GET", "/api/v1/notebook/cell", serve_api_cell)

    # Read ONE cell's rendered figure as raw image bytes — opt-in (separate request), so figures
    # never bloat `status`. Only when the cell's output mime is image/* (png/svg/jpeg/…).
    function serve_api_figure(request::HTTP.Request)
        query = HTTP.queryparams(HTTP.URI(request.target))
        notebook = _api_notebook_from_query(session, query)
        notebook === nothing && return _api_error(404, "notebook not found — is it open? (pass ?path= or ?id=)", true)
        haskey(query, "cell") || return _api_error(400, "specify ?cell=<uuid>", true)
        cid = try
            UUID(strip(query["cell"]))
        catch
            return _api_error(400, "invalid cell id: $(query["cell"])", true)
        end
        haskey(notebook.cells_dict, cid) || return _api_error(404, "no cell with id $(query["cell"])", true)
        cell = notebook.cells_dict[cid]
        mime = string(cell.output.mime)
        startswith(mime, "image/") || return _api_error(415, "cell $(cell.cell_id) output is $(mime), not an image — use `status`/the cell endpoint for text & rich results", true)
        body = cell.output.body
        bytes = body isa Vector{UInt8} ? body :
                body isa String ? Vector{UInt8}(codeunits(body)) :
                return _api_error(404, "cell $(cell.cell_id) has no image bytes", true)
        HTTP.Response(200, ["Content-Type" => mime], bytes)
    end
    HTTP.register!(router, "GET", "/api/v1/notebook/figure", serve_api_figure)

    function serve_api_run(request::HTTP.Request)
        query = HTTP.queryparams(HTTP.URI(request.target))
        fmt_text = _api_wants_text(query)
        notebook = _api_notebook_from_query(session, query)
        notebook === nothing && return _api_error(404, "notebook not found — is it open in this server? (pass ?path=/abs/path.jl or ?id=<uuid>)", fmt_text)

        cells = if get(query, "stale", "") == "true"
            filter(c -> c.stale, notebook.cells)
        elseif haskey(query, "cells")
            ids = split(query["cells"], ',')
            resolved = Cell[]
            for id_str in ids
                id = try
                    UUID(strip(id_str))
                catch
                    return _api_error(400, "invalid cell id: $id_str", fmt_text)
                end
                haskey(notebook.cells_dict, id) || return _api_error(404, "no cell with id $id_str", fmt_text)
                push!(resolved, notebook.cells_dict[id])
            end
            resolved
        else
            return _api_error(400, "specify ?stale=true or ?cells=<id>,<id>,…", fmt_text)
        end

        requested_ids = Set(cell_id.(cells))
        if is_lazy(session)
            cells = expand_stale_ancestors(notebook, cells)
        end

        if !isempty(cells)
            # blocking: the same path as a browser run request, behind the same execution token
            update_save_run!(session, notebook, cells; run_async=false, save=true, auto_solve_multiple_defs=true)
        end

        n_errored = count(c -> c.errored, cells)
        headers = [
            "Content-Type" => fmt_text ? "text/plain; charset=utf-8" : "application/json; charset=utf-8",
            "X-Pluto-Cells-Ran" => string(length(cells)),
            "X-Pluto-Cells-Errored" => string(n_errored),
        ]
        if fmt_text
            lines = String[]
            for (i, c) in enumerate(cells)
                requested = cell_id(c) ∈ requested_ids ? "" : " (pulled in)"
                push!(lines, _api_cell_text_line(notebook, i, c) * requested)
            end
            push!(lines, n_errored == 0 ? "RESULT: ok ($(length(cells)) cells ran)" : "RESULT: errored ($(n_errored) of $(length(cells)) cells errored)")
            HTTP.Response(200, headers, join(lines, "\n") * "\n")
        else
            body = _json(Pair[
                "ok" => n_errored == 0,
                "cells_ran" => length(cells),
                "cells_errored" => n_errored,
                "cells" => [vcat(_api_cell_pairs(c), Pair["pulled_in" => cell_id(c) ∉ requested_ids]) for c in cells],
            ])
            HTTP.Response(200, headers, body * "\n")
        end
    end
    HTTP.register!(router, "POST", "/api/v1/notebook/run", serve_api_run)

    function serve_api_browse(request::HTTP.Request)
        query = HTTP.queryparams(HTTP.URI(request.target))
        path = haskey(query, "path") ? tamepath(query["path"]) : homedir()
        isdir(path) || return _api_error(404, "not a directory: $path", false)
        dirs = String[]
        try
            for name in sort(readdir(path))
                startswith(name, ".") && continue
                isdir(joinpath(path, name)) && push!(dirs, name)
            end
        catch end
        body = _json(Pair["path" => path, "parent" => dirname(path), "dirs" => dirs])
        HTTP.Response(200, ["Content-Type" => "application/json; charset=utf-8"], body * "\n")
    end
    HTTP.register!(router, "GET", "/api/v1/browse", serve_api_browse)

    function serve_api_workspace_open(request::HTTP.Request)
        query = HTTP.queryparams(HTTP.URI(request.target))
        haskey(query, "path") || return _api_error(400, "pass ?path=/abs/folder", false)
        path = tamepath(query["path"])
        isdir(path) || return _api_error(400, "not a directory: $path", false)
        session.options.server.workspace_folder = path
        # refresh the connection file so external tools see the new workspace root
        port = session.options.server.port
        port isa Integer && try
            write_collab_registry_file(session, port)
        catch end
        # opt-in: seed the newly-opened workspace's AGENTS.md/CLAUDE.md collab section
        try
            maybe_write_agents_md(session)
        catch end
        HTTP.Response(200, ["Content-Type" => "application/json; charset=utf-8"], _json(Pair["ok" => true, "root" => path]) * "\n")
    end
    HTTP.register!(router, "POST", "/api/v1/workspace/open", serve_api_workspace_open)

    # Clear the workspace (back to the launcher) — the "home" button on a tunneled server switches
    # workspaces in-place rather than opening new tabs, so it needs a way to return to the homebase.
    function serve_api_workspace_close(request::HTTP.Request)
        session.options.server.workspace_folder = nothing
        port = session.options.server.port
        port isa Integer && try
            write_collab_registry_file(session, port)
        catch end
        HTTP.Response(200, ["Content-Type" => "application/json; charset=utf-8"], _json(Pair["ok" => true]) * "\n")
    end
    HTTP.register!(router, "POST", "/api/v1/workspace/close", serve_api_workspace_close)

    # Capabilities the frontend needs even before a workspace exists. `tunneled` = this server is reached
    # over an SSH tunnel (set at remote launch): its child workspace ports aren't forwarded to the browser,
    # so the launcher opens workspaces IN-PLACE instead of spawning unreachable child tabs.
    function serve_api_config(request::HTTP.Request)
        body = _json(Pair[
            "tunneled" => haskey(ENV, "PLUTOSPACE_TUNNELED"),
            "pluto_version" => PLUTO_VERSION_STR,
        ])
        HTTP.Response(200, ["Content-Type" => "application/json; charset=utf-8"], body * "\n")
    end
    HTTP.register!(router, "GET", "/api/v1/config", serve_api_config)

    function serve_api_ssh_hosts(request::HTTP.Request)
        # the user's already-keyed remotes: Host entries from ~/.ssh/config (wildcards skipped)
        hosts = String[]
        config = joinpath(homedir(), ".ssh", "config")
        if isfile(config)
            for line in eachline(config)
                m = match(r"^\s*Host\s+(.+)$"i, line)
                m === nothing && continue
                for h in split(m.captures[1])
                    (occursin('*', h) || occursin('?', h) || occursin('!', h)) && continue
                    push!(hosts, String(h))
                end
            end
        end
        body = _json(unique(hosts))
        HTTP.Response(200, ["Content-Type" => "application/json; charset=utf-8"], body * "\n")
    end
    HTTP.register!(router, "GET", "/api/v1/ssh_hosts", serve_api_ssh_hosts)

    function serve_api_workspace(request::HTTP.Request)
        ws = session.options.server.workspace_folder
        ws === nothing && return _api_error(404, "this server has no workspace folder — start with PlutoSpace.run(workspace=\"/path\")", false)
        root = tamepath(ws)
        isdir(root) || return _api_error(404, "workspace folder does not exist: $root", false)
        body = _json(Pair[
            "root" => root,
            "entries" => _workspace_entries(root),
            "git" => _git_workspace_info(root),
        ])
        HTTP.Response(200, ["Content-Type" => "application/json; charset=utf-8"], body * "\n")
    end
    HTTP.register!(router, "GET", "/api/v1/workspace", serve_api_workspace)

    function serve_api_file_get(request::HTTP.Request)
        query = HTTP.queryparams(HTTP.URI(request.target))
        haskey(query, "path") || return _api_error(400, "pass ?path=/abs/file", false)
        path = tamepath(query["path"])
        isfile(path) || return _api_error(404, "not a file: $path", false)
        filesize(path) > 2_000_000 && return _api_error(413, "file too large to edit here (> 2 MB)", false)
        content = try
            read(path, String)
        catch
            return _api_error(500, "could not read file", false)
        end
        isvalid(content) || return _api_error(415, "not a UTF-8 text file", false)
        HTTP.Response(200, ["Content-Type" => "text/plain; charset=utf-8"], content)
    end
    HTTP.register!(router, "GET", "/api/v1/file", serve_api_file_get)

    function serve_api_file_save(request::HTTP.Request)
        query = HTTP.queryparams(HTTP.URI(request.target))
        haskey(query, "path") || return _api_error(400, "pass ?path=/abs/file", false)
        path = tamepath(query["path"])
        isdir(dirname(path)) || return _api_error(400, "no such directory: $(dirname(path))", false)
        try
            # atomic, like the notebook save path
            tmp = path * ".plutospace_tmp"
            write(tmp, request.body)
            mv(tmp, path; force=true)
        catch e
            return _api_error(500, "could not save: $(sprint(showerror, e))", false)
        end
        HTTP.Response(200, ["Content-Type" => "application/json; charset=utf-8"], """{"ok": true}\n""")
    end
    HTTP.register!(router, "POST", "/api/v1/file/save", serve_api_file_save)

    function serve_api_file_new(request::HTTP.Request)
        query = HTTP.queryparams(HTTP.URI(request.target))
        haskey(query, "path") || return _api_error(400, "pass ?path=/abs/file", false)
        path = tamepath(query["path"])
        isfile(path) && return _api_error(409, "file already exists: $path", false)
        isdir(dirname(path)) || return _api_error(400, "no such directory: $(dirname(path))", false)
        try
            write(path, "")
        catch e
            return _api_error(500, "could not create: $(sprint(showerror, e))", false)
        end
        HTTP.Response(200, ["Content-Type" => "application/json; charset=utf-8"], """{"ok": true}\n""")
    end
    HTTP.register!(router, "POST", "/api/v1/file/new", serve_api_file_new)

    function serve_api_file_delete(request::HTTP.Request)
        query = HTTP.queryparams(HTTP.URI(request.target))
        haskey(query, "path") || return _api_error(400, "pass ?path=/abs/file", false)
        path = tamepath(query["path"])
        isfile(path) || return _api_error(404, "not a file: $path", false)
        # if it's a notebook running in this session, shut it down first
        for nb in collect(values(session.notebooks))
            if isfile(nb.path) && realpath(nb.path) == realpath(path)
                SessionActions.shutdown(session, nb; keep_in_session=false, async=false, verbose=false)
            end
        end
        try
            rm(path)
            # a notebook's output cache goes with it
            sidecar = path * OUTPUT_CACHE_SUFFIX
            isfile(sidecar) && rm(sidecar)
        catch e
            return _api_error(500, "could not delete: $(sprint(showerror, e))", false)
        end
        HTTP.Response(200, ["Content-Type" => "application/json; charset=utf-8"], """{"ok": true}\n""")
    end
    HTTP.register!(router, "POST", "/api/v1/file/delete", serve_api_file_delete)

    function serve_api_interrupt(request::HTTP.Request)
        query = HTTP.queryparams(HTTP.URI(request.target))
        fmt_text = _api_wants_text(query)
        notebook = _api_notebook_from_query(session, query)
        notebook === nothing && return _api_error(404, "notebook not found", fmt_text)

        # same logic as the :interrupt_all websocket message
        session_notebook = (session, notebook)
        workspace = WorkspaceManager.get_workspace(session_notebook; allow_creation=false)
        anything_running = workspace !== nothing && !isready(workspace.dowork_token) && any(c -> c.running, notebook.cells)
        if !notebook.wants_to_interrupt && anything_running
            notebook.wants_to_interrupt = true
            WorkspaceManager.interrupt_workspace(session_notebook)
        end
        HTTP.Response(200, fmt_text ? "interrupt requested\n" : """{"ok": true}\n""")
    end
    HTTP.register!(router, "POST", "/api/v1/notebook/interrupt", serve_api_interrupt)

    # Restart the notebook's worker process and re-run every cell — the agent-facing equivalent of the
    # editor's "restart" button (see restart_notebook_process! in Dynamic.jl). This is the recovery path
    # for a worker that has died/exited (Malt.TerminatedWorkerException, "Process exited"): `interrupt`
    # only stops a running cell and `run` needs a live process, so neither can revive a crashed kernel —
    # `restart` can. Blocking like /run: the response is held until the fresh process has re-run the
    # notebook, then reports the resulting cell states (X-Pluto-Cells-Errored header, exit 1 for clients).
    function serve_api_restart(request::HTTP.Request)
        query = HTTP.queryparams(HTTP.URI(request.target))
        fmt_text = _api_wants_text(query)
        notebook = _api_notebook_from_query(session, query)
        notebook === nothing && return _api_error(404, "notebook not found — is it open in this server? (pass ?path=/abs/path.jl or ?id=<uuid>)", fmt_text)

        # same execution path as the browser's restart; synchronous so the HTTP call blocks until the re-run finishes
        restart_notebook_process!(session, notebook; run_async=false)

        n_errored = count(c -> c.errored, notebook.cells)
        headers = [
            "Content-Type" => fmt_text ? "text/plain; charset=utf-8" : "application/json; charset=utf-8",
            "X-Pluto-Cells-Ran" => string(length(notebook.cells)),
            "X-Pluto-Cells-Errored" => string(n_errored),
        ]
        if fmt_text
            lines = [_api_cell_text_line(notebook, i, c) for (i, c) in enumerate(notebook.cells)]
            push!(lines, n_errored == 0 ? "RESULT: restarted, $(length(notebook.cells)) cells ran ok" : "RESULT: restarted, $(n_errored) of $(length(notebook.cells)) cells errored")
            HTTP.Response(200, headers, join(lines, "\n") * "\n")
        else
            body = _json(Pair[
                "ok" => n_errored == 0,
                "restarted" => true,
                "cells_ran" => length(notebook.cells),
                "cells_errored" => n_errored,
                "process_status" => notebook.process_status,
                "cells" => [_api_cell_pairs(c) for c in notebook.cells],
            ])
            HTTP.Response(200, headers, body * "\n")
        end
    end
    HTTP.register!(router, "POST", "/api/v1/notebook/restart", serve_api_restart)
end
