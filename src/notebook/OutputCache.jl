import TOML
import Base64: base64encode, base64decode

###
# The output cache sidecar: `<notebook>.jl.pluto-cache.toml`
#
# A pure, deletable cache of cell outputs, written after every reactive run in lazy mode.
# It serves two purposes:
#
#  1. Restart-surviving outputs: when a notebook is opened in lazy mode, cached outputs are
#     restored and verified against each cell's execution key — cells whose code (and upstream
#     results) are unchanged show their old output immediately, marked "cold" rather than re-run.
#  2. An agent-readable view of the notebook's results: the sidecar is plain TOML with a
#     truncated text representation, error message, and timing per cell, so any external tool
#     can read outputs by reading a file. (Full-fidelity output data is in `output_packed`.)
#
# The notebook file itself stays byte-compatible with vanilla Pluto. Deleting the sidecar
# costs nothing but cached outputs.
###

const OUTPUT_CACHE_FORMAT = 1
const OUTPUT_CACHE_SUFFIX = ".pluto-cache.toml"
const TEXT_REPRESENTATION_LIMIT = 20_000

output_cache_path(notebook::Notebook) = notebook.path * OUTPUT_CACHE_SUFFIX

function _output_to_dict(output::CellOutput)::Dict{String,Any}
    Dict{String,Any}(
        "body" => output.body,
        "mime" => string(output.mime),
        "rootassignee" => output.rootassignee === nothing ? nothing : string(output.rootassignee),
        "last_run_timestamp" => output.last_run_timestamp,
        "persist_js_state" => output.persist_js_state,
        "has_pluto_hook_features" => output.has_pluto_hook_features,
    )
end

function _output_from_dict(d::Dict)::CellOutput
    CellOutput(
        body=get(d, "body", nothing),
        mime=MIME(get(d, "mime", "text/plain")),
        rootassignee=let r = get(d, "rootassignee", nothing)
            r === nothing ? nothing : Symbol(r)
        end,
        last_run_timestamp=get(d, "last_run_timestamp", 0.0),
        persist_js_state=get(d, "persist_js_state", false),
        has_pluto_hook_features=get(d, "has_pluto_hook_features", false),
    )
end

"A plain-text view of a cell's output, for humans and external tools (the sidecar digest, and the
agent API). `limit` caps the length — the status digest uses the default; the per-cell API endpoint
passes a larger limit so an agent can read a cell's full result."
function _text_representation(cell::Cell; limit::Integer=TEXT_REPRESENTATION_LIMIT)::String
    body = cell.output.body
    if cell.errored && body isa Dict
        msg = get(body, :msg, get(body, "msg", ""))
        msg isa String ? first(msg, limit) : "[error]"
    elseif body isa String
        length(body) > limit ?
            first(body, limit) * "\n…[truncated $(length(body) - limit) characters — full output in output_packed]" :
            body
    elseif body isa Vector{UInt8}
        "[binary output: $(cell.output.mime), $(length(body)) bytes — fetch it with `pluto-collab figure`]"
    elseif body isa Dict
        # rich (tree/table) output: use the plain-text repr captured in the worker
        isempty(cell.output_text) ?
            "[rich output: $(cell.output.mime) — open in Pluto, or unpack output_packed]" :
            first(cell.output_text, limit)
    else
        ""
    end
end

"""
Write the output cache sidecar for this notebook (atomic). Includes, per cell: the execution key and result hash (for verification on load), agent-readable text, and a MsgPack+Base64 packed copy of the full output for exact restore.
"""
function save_output_cache(notebook::Notebook)
    cells_dict = Dict{String,Any}()
    for cell in notebook.cells
        # only cells that have produced output are worth caching
        cell.execution_key_produced == 0 && continue
        packed = try
            base64encode(pack(Dict{String,Any}(
                "output" => _output_to_dict(cell.output),
                "published_objects" => cell.published_objects,
            )))
        catch e
            @debug "Could not pack cell output for cache" cell.cell_id exception = e
            nothing
        end
        entry = Dict{String,Any}(
            "execution_key" => string(cell.execution_key_produced, base=16),
            "result_hash" => string(cell.result_hash, base=16),
            "errored" => cell.errored,
            "mime" => string(cell.output.mime),
            "text_representation" => _text_representation(cell),
        )
        cell.runtime === nothing || (entry["runtime_ns"] = Int64(min(cell.runtime, typemax(Int64) % UInt64)))
        packed === nothing || (entry["output_packed"] = packed)
        cells_dict[string(cell.cell_id)] = entry
    end

    content_dict = Dict{String,Any}(
        "format" => OUTPUT_CACHE_FORMAT,
        "pluto_version" => PLUTO_VERSION_STR,
        "julia_version" => JULIA_VERSION_STR,
        "cell_order" => string.(notebook.cell_order),
        "cells" => cells_dict,
    )

    path = output_cache_path(notebook)
    tmp = path * ".tmp"
    Base.open(tmp, "w") do io
        TOML.print(io, content_dict; sorted=true)
    end
    mv(tmp, path; force=true)
end

"""
Restore cell outputs, execution keys and result hashes from the output cache sidecar, if present. Restored cells are flagged `workspace_cold`: their *display* is current, but their variables do not exist in the (fresh) workspace, so they are pulled in like stale cells when something downstream runs. Best-effort: a missing or unreadable cache restores nothing.
"""
function load_output_cache!(notebook::Notebook)::Bool
    path = output_cache_path(notebook)
    isfile(path) || return false
    data = try
        TOML.parsefile(path)
    catch e
        @warn "Output cache exists but could not be read — ignoring it. (It is a cache: you can safely delete it.)" path exception = e
        return false
    end
    get(data, "format", 0) == OUTPUT_CACHE_FORMAT || return false

    cells_data = get(data, "cells", Dict{String,Any}())
    for cell in notebook.cells
        entry = get(cells_data, string(cell.cell_id), nothing)
        entry === nothing && continue
        try
            cell.execution_key_produced = parse(UInt64, entry["execution_key"], base=16)
            cell.result_hash = parse(UInt64, entry["result_hash"], base=16)
            cell.errored = get(entry, "errored", false)
            haskey(entry, "runtime_ns") && (cell.runtime = UInt64(entry["runtime_ns"]))
            if haskey(entry, "output_packed")
                unpacked = unpack(base64decode(entry["output_packed"]))
                cell.output = _output_from_dict(unpacked["output"])
                cell.published_objects = let po = get(unpacked, "published_objects", nothing)
                    po isa Dict ? Dict{String,Any}(po) : Dict{String,Any}()
                end
            end
            haskey(entry, "text_representation") && isempty(cell.output_text) && (cell.output_text = entry["text_representation"])
            cell.workspace_cold = true
        catch e
            @debug "Skipping unreadable cache entry" cell.cell_id exception = e
        end
    end
    return true
end
