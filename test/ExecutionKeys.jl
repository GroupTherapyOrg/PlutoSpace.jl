using Test
import Pluto: Pluto, Notebook, ServerSession, SessionActions, Cell, update_run!, update_save_run!

@testset "Execution keys (verifying trace)" begin
    🍭 = ServerSession()
    🍭.options.evaluation.workspace_use_distributed = false
    🍭.options.evaluation.on_code_change = "lazy"

    notebook = SessionActions.new(🍭; run_async=false)
    nb1 = Notebook([
        Cell("a = 1"),
        Cell("b = a + 1"),
        Cell("c = b + 1"),
    ])
    write(notebook.path, sprint(Pluto.save_notebook, nb1))
    @test Pluto.update_from_file(🍭, notebook)
    a, b, c = notebook.cells

    @testset "keys are recorded after running" begin
        @test all(cell -> cell.execution_key_produced != 0, notebook.cells)
        @test all(cell -> cell.result_hash != 0, notebook.cells)
        @test all(cell -> Pluto.current_execution_key(cell) == cell.execution_key_produced, notebook.cells)
        @test Pluto.immediate_upstream_cells(b) == [a]
        @test Pluto.immediate_upstream_cells(c) == [b]
    end

    @testset "reverting an edit un-stales the whole closure" begin
        file = read(notebook.path, String)
        write(notebook.path, replace(file, "a = 1" => "a = 2"))
        @test Pluto.update_from_file(🍭, notebook)
        @test a.stale && b.stale && c.stale

        write(notebook.path, file)
        @test Pluto.update_from_file(🍭, notebook)
        # the code is back to exactly what produced the outputs — verification clears everything, no runs needed
        @test !a.stale && !b.stale && !c.stale
        @test a.output.body == "1"
    end

    @testset "early cutoff: same result upstream clears downstream" begin
        file = read(notebook.path, String)
        write(notebook.path, replace(file, "a = 1" => "a = 1 #hi"))
        @test Pluto.update_from_file(🍭, notebook)
        @test a.stale && b.stale && c.stale

        # simulate "a re-ran and produced the same result" without running b and c
        a.code == "a = 1 #hi" || error("test setup wrong")
        Pluto.record_execution_key!(a) # result unchanged (output still \"1\"), key now reflects the new code
        a.stale = false

        cleared = Pluto.verify_stale!(notebook)
        # b and c's execution keys are unchanged (their code and their upstream RESULTS are the same), so they are provably current
        @test Set(cleared) == Set([b, c])
        @test !b.stale && !c.stale
    end

    @testset "no false clears: changed upstream result keeps downstream stale" begin
        file = read(notebook.path, String)
        write(notebook.path, replace(file, "a = 1 #hi" => "a = 5"))
        @test Pluto.update_from_file(🍭, notebook)
        @test a.stale && b.stale && c.stale

        # simulate "a re-ran and produced a DIFFERENT result"
        a.result_hash = hash("something else entirely")
        a.execution_key_produced = Pluto.current_execution_key(a)
        a.stale = false

        Pluto.verify_stale!(notebook)
        # b's key no longer matches (upstream result hash changed) — must stay stale
        @test b.stale && c.stale

        # undo the simulation: cell a's code (\"a = 5\") really never ran
        a.stale = true
    end

    @testset "a real run through the engine clears everything" begin
        update_run!(🍭, notebook, Pluto.expand_stale_ancestors(notebook, filter(cell -> cell.stale, notebook.cells)))
        @test all(cell -> !cell.stale, notebook.cells)
        @test a.output.body == "5"
        @test b.output.body == "6"
        @test c.output.body == "7"
        @test all(cell -> Pluto.current_execution_key(cell) == cell.execution_key_produced, notebook.cells)
    end

    @testset "always_stale cells are never auto-cleared" begin
        file = read(notebook.path, String)
        # mark cell a as always_stale via its in-file metadata, with unchanged code
        @assert occursin("# ╔═╡ $(a.cell_id)\n", file)
        file_with_metadata = replace(file, "# ╔═╡ $(a.cell_id)\n" => "# ╔═╡ $(a.cell_id)\n# ╠═╡ always_stale = true\n")
        write(notebook.path, file_with_metadata)
        @test Pluto.update_from_file(🍭, notebook)
        @test Pluto.is_always_stale(a)

        # a metadata-only change marks the cell stale (its file representation changed); verification must NOT clear it, even though code and upstream are identical
        @test a.stale
    end

    SessionActions.shutdown(🍭, notebook)
end
