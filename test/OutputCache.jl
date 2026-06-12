using Test
import PlutoLand: Pluto, Notebook, ServerSession, SessionActions, Cell, update_run!

@testset "Output cache sidecar" begin
    🍭 = ServerSession()
    🍭.options.evaluation.workspace_use_distributed = false
    🍭.options.evaluation.on_code_change = "lazy"

    notebook = SessionActions.new(🍭; run_async=false)
    path = notebook.path
    cache_path = path * Pluto.OUTPUT_CACHE_SUFFIX

    nb1 = Notebook([
        Cell("a = 1"),
        Cell("b = a + 1"),
        Cell("d = b * 2"),
        Cell("c = rand()"),
    ])
    write(path, sprint(Pluto.save_notebook, nb1))
    @test Pluto.update_from_file(🍭, notebook) # cell-removal fallback: runs everything
    @test notebook.cells[3].output.body == "4"
    rand_output = notebook.cells[4].output.body

    @testset "rich (tree) outputs get readable text for agents" begin
        # a Vector renders as Pluto's tree object — output_text/sidecar must still be readable
        nb_v = SessionActions.new(🍭; run_async=false)
        write(nb_v.path, sprint(Pluto.save_notebook, Notebook([Cell("v = [10, 20, 30]")])))
        @test Pluto.update_from_file(🍭, nb_v)
        txt = Pluto._text_representation(nb_v.cells[1])
        @test occursin("10", txt) && occursin("20", txt) && occursin("30", txt)
        @test !occursin("unpack output_packed", txt)
        SessionActions.shutdown(🍭, nb_v; async=false)
        rm(nb_v.path * Pluto.OUTPUT_CACHE_SUFFIX; force=true)
    end

    @testset "sidecar is written after a run" begin
        @test isfile(cache_path)
        data = read(cache_path, String)
        @test occursin("execution_key", data)
        @test occursin("text_representation", data)
        # agent-readable: the plain text of an output is in the file
        @test occursin("\"4\"", data) || occursin("text_representation = \"4\"", data)
    end

    SessionActions.shutdown(🍭, notebook; async=false)

    @testset "outputs survive a restart" begin
        🍭2 = ServerSession()
        🍭2.options.evaluation.workspace_use_distributed = false
        🍭2.options.evaluation.on_code_change = "lazy"

        nb2 = SessionActions.open(🍭2, path; run_async=false)
        a, b, d, c = nb2.cells

        # outputs restored from cache, verified current, nothing ran
        @test a.output.body == "1"
        @test b.output.body == "2"
        @test d.output.body == "4"
        @test c.output.body == rand_output
        @test all(cell -> !cell.stale, nb2.cells)
        @test all(cell -> cell.workspace_cold, nb2.cells)

        # running d pulls its cold ancestors a and b — but not the unrelated c
        update_run!(🍭2, nb2, Pluto.expand_stale_ancestors(nb2, Cell[d]))
        @test d.output.body == "4"
        @test !a.workspace_cold && !b.workspace_cold && !d.workspace_cold
        @test c.workspace_cold
        @test c.output.body == rand_output # cached display, untouched

        SessionActions.shutdown(🍭2, nb2; async=false)
    end

    @testset "an edit while the server was off shows up as stale on open" begin
        file = read(path, String)
        write(path, replace(file, "b = a + 1" => "b = a + 2"))

        🍭3 = ServerSession()
        🍭3.options.evaluation.workspace_use_distributed = false
        🍭3.options.evaluation.on_code_change = "lazy"

        nb3 = SessionActions.open(🍭3, path; run_async=false)
        a, b, d, c = nb3.cells

        @test !a.stale # unchanged, verified from cache
        @test b.stale  # edited while server was off
        @test !d.stale # depends on b, but only edited cells are marked — it re-runs reactively when b runs
        @test !c.stale # unrelated (cached rand value is trusted — see always_stale for opting out)
        @test b.output.body == "2" # old output still displayed

        update_run!(🍭3, nb3, Pluto.expand_stale_ancestors(nb3, filter(cell -> cell.stale, nb3.cells)))
        @test b.output.body == "3"
        @test d.output.body == "6"
        @test c.output.body == rand_output

        SessionActions.shutdown(🍭3, nb3; async=false)
    end

    @testset "cold ancestors of the run's downstream closure are pulled" begin
        🍭4 = ServerSession()
        🍭4.options.evaluation.workspace_use_distributed = false
        🍭4.options.evaluation.on_code_change = "lazy"
        nb4 = SessionActions.new(🍭4; run_async=false)
        path4 = nb4.path
        # two branches that only meet at the bottom: f depends on b's branch AND on c
        write(path4, sprint(Pluto.save_notebook, Notebook([
            Cell("a2 = 1"),
            Cell("b2 = a2 + 1"),
            Cell("c2 = 10"),
            Cell("f2 = b2 + c2"),
        ])))
        @test Pluto.update_from_file(🍭4, nb4) # runs everything (cell-removal fallback)
        @test nb4.cells[4].output.body == "12"
        SessionActions.shutdown(🍭4, nb4; async=false)

        🍭5 = ServerSession()
        🍭5.options.evaluation.workspace_use_distributed = false
        🍭5.options.evaluation.on_code_change = "lazy"
        nb5 = SessionActions.open(🍭5, path4; run_async=false)
        a2, b2, c2, f2 = nb5.cells
        @test all(cell -> cell.workspace_cold, nb5.cells)

        # running the TOP cell a2 reactively re-runs b2 and f2 — and f2 also needs c2, which is cold and NOT an ancestor of a2. The expansion must pull it in, or f2 would hit an UndefVarError.
        to_run = Pluto.expand_stale_ancestors(nb5, Cell[a2])
        @test c2 ∈ to_run

        update_run!(🍭5, nb5, to_run)
        @test !f2.errored
        @test f2.output.body == "12"
        @test !c2.workspace_cold

        SessionActions.shutdown(🍭5, nb5; async=false)
        rm(path4 * Pluto.OUTPUT_CACHE_SUFFIX; force=true)
    end

    isfile(cache_path) && rm(cache_path)
end
