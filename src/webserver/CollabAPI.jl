###
# The collab HTTP API: how external tools (coding agents, scripts, CI) talk to a LIVE PlutoLand server.
#
# Design constraints (deliberate):
#  - Plain HTTP + the existing Pluto secret for auth (`?secret=...` or cookie) — curl-able from
#    any terminal, no protocol stack, no registration. Works for any tool that can run curl.
#  - Input via query parameters, output as JSON (`format=json`, default) or plain text
#    (`format=text`) — so a thin shell client needs no JSON parser at all.
#  - Server discovery via a connection file (like Jupyter's kernel-*.json): every running server
#    writes `$XDG_STATE_HOME/pluto/servers/<port>.json` with its port and secret.
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
collab_registry_path(port::Integer) = joinpath(collab_registry_dir(), "$(port).json")

"Write the connection file that lets external tools discover this live server (port + secret). Flat JSON, greppable with sed — clients need no JSON parser."
function write_collab_registry_file(session::ServerSession, port::Integer)
    dir = collab_registry_dir()
    mkpath(dir)
    path = collab_registry_path(port)
    ws = session.options.server.workspace_folder
    write(path, """{"pid": $(getpid()), "host": $(_json_string(session.options.server.host)), "port": $(port), "secret": $(_json_string(session.secret)), "workspace": $(ws === nothing ? "null" : _json_string(tamepath(ws))), "pluto_version": $(_json_string(PLUTO_VERSION_STR)), "started_at": $(time())}\n""")
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

# --- the workspace tree (PlutoLand) ---

"Does this file look like a Pluto notebook? (`.jl` extension + the Pluto header on line 1)"
function _is_pluto_notebook_file(path::String)::Bool
    endswith(path, ".jl") || return false
    try
        Base.open(io -> startswith(readline(io), _notebook_header), path, "r")
    catch
        false
    end
end

const _WORKSPACE_SKIPLIST = ("node_modules", "frontend-dist")

"Recursive listing of a workspace folder as JSON-able pairs. Depth- and entry-budgeted; hidden files and bulky tool directories are skipped."
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
        startswith(name, ".") && continue
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
        HTTP.Response(200, ["Content-Type" => "application/json; charset=utf-8"], _json(Pair["ok" => true, "root" => path]) * "\n")
    end
    HTTP.register!(router, "POST", "/api/v1/workspace/open", serve_api_workspace_open)

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
        ws === nothing && return _api_error(404, "this server has no workspace folder — start with PlutoLand.run(workspace=\"/path\")", false)
        root = tamepath(ws)
        isdir(root) || return _api_error(404, "workspace folder does not exist: $root", false)
        body = _json(Pair[
            "root" => root,
            "entries" => _workspace_entries(root),
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
            tmp = path * ".plutoland_tmp"
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
end
