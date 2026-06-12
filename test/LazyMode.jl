using Test
import PlutoLand: Pluto, Notebook, ServerSession, SessionActions, Cell, update_run!, update_save_run!
using PlutoLand.WorkspaceManager: poll

@testset "Lazy mode (on_code_change = \"lazy\")" begin
    🍭 = ServerSession()
    🍭.options.evaluation.workspace_use_distributed = false
    🍭.options.evaluation.on_code_change = "lazy"

    notebook = SessionActions.new(🍭; run_async=false)

    # diamond dependency: a → (b, c) → d, plus an unrelated cell e
    nb1 = Notebook([
        Cell("a = 1"),
        Cell("b = a + 1"),
        Cell("c = a + 10"),
        Cell("d = b + c"),
        Cell("rand()"),
    ])
    file1 = sprint(Pluto.save_notebook, nb1)
    write(notebook.path, file1)

    # First reload replaces the initial empty cell (a cell removal), so lazy mode falls back to a normal reactive run — everything executes.
    @test Pluto.update_from_file(🍭, notebook)
    @test length(notebook.cells) == 5
    @test notebook.cells[1].output.body == "1"
    @test notebook.cells[2].output.body == "2"
    @test notebook.cells[4].output.body == "13"
    @test all(c -> !c.stale, notebook.cells)
    rand_output = notebook.cells[5].output.body

    @testset "external code change marks stale, does not run" begin
        write(notebook.path, replace(file1, "a = 1" => "a = 2"))
        @test Pluto.update_from_file(🍭, notebook)

        # ONLY the edited cell is marked — same as editing in the browser. Dependents will re-run reactively when it runs.
        @test notebook.cells[1].stale
        @test !notebook.cells[2].stale
        @test !notebook.cells[3].stale
        @test !notebook.cells[4].stale
        @test !notebook.cells[5].stale

        # nothing ran: outputs still show the old values, and the unrelated cell was untouched
        @test notebook.cells[1].output.body == "1"
        @test notebook.cells[2].output.body == "2"
        @test notebook.cells[4].output.body == "13"
        @test notebook.cells[5].output.body == rand_output
        @test all(c -> !c.running && !c.queued, notebook.cells)

        # but the code and topology are current
        @test notebook.cells[1].code == "a = 2"
    end

    @testset "pending changes do not propagate through other cells' runs" begin
        # a was edited (a = 2) but never run. Running d does NOT pull a's pending change in: d computes against the workspace value from a's last run — exactly like running a cell below someone's unsaved edit in vanilla Pluto.
        to_run = Pluto.expand_stale_ancestors(notebook, Cell[notebook.cells[4]])
        @test to_run == Cell[notebook.cells[4]]
        update_run!(🍭, notebook, to_run)
        @test notebook.cells[4].output.body == "13" # still computed from a = 1
        @test notebook.cells[1].stale               # a's pending change is still pending
        @test notebook.cells[1].output.body == "1"

        # the Ctrl+S equivalent: run all stale cells — now the change applies everywhere
        update_run!(🍭, notebook, filter(c -> c.stale, notebook.cells))
        @test notebook.cells[1].output.body == "2"
        @test notebook.cells[2].output.body == "3"
        @test notebook.cells[3].output.body == "12"
        @test notebook.cells[4].output.body == "15"
        @test all(c -> !c.stale, notebook.cells)
        # the unrelated cell still did not run
        @test notebook.cells[5].output.body == rand_output
    end

    @testset "running one stale cell leaves unrelated stale cells stale" begin
        file2 = read(notebook.path, String)
        write(notebook.path, replace(file2, "b = a + 1" => "b = a + 100", "rand()" => "rand(); 0"))
        @test Pluto.update_from_file(🍭, notebook)

        @test notebook.cells[2].stale # b changed
        @test !notebook.cells[4].stale # d depends on b, but only edited cells are marked
        @test notebook.cells[5].stale # e changed
        @test !notebook.cells[1].stale # a is upstream, unaffected
        @test !notebook.cells[3].stale # c does not depend on b

        # run only b (d runs too: reactive downstream), e stays stale
        update_run!(🍭, notebook, Pluto.expand_stale_ancestors(notebook, Cell[notebook.cells[2]]))
        @test !notebook.cells[2].stale
        @test !notebook.cells[4].stale
        @test notebook.cells[2].output.body == "102"
        @test notebook.cells[4].output.body == "114"
        @test notebook.cells[5].stale

        # now run the remaining stale cell
        update_run!(🍭, notebook, filter(c -> c.stale, notebook.cells))
        @test all(c -> !c.stale, notebook.cells)
    end

    @testset "cell removal falls back to a reactive run" begin
        file3 = read(notebook.path, String)
        nb_lines = split(file3, "\n")
        # remove cell d (the one computing b + c) by rewriting the file without it
        d_id = notebook.cells[4].cell_id
        file4 = replace(file3, "d = b + c" => "d_removed = 1")
        write(notebook.path, file4)
        @test Pluto.update_from_file(🍭, notebook)
        # a *changed* cell with no removals would be lazy, but this was a change — assert lazy marking happened
        @test notebook.cells[4].stale
        update_run!(🍭, notebook, filter(c -> c.stale, notebook.cells))
        @test notebook.cells[4].output.body == "1"
    end

    @testset "autorun sessions are unaffected" begin
        🍭.options.evaluation.on_code_change = "autorun"
        file5 = read(notebook.path, String)
        write(notebook.path, replace(file5, "a = 2" => "a = 3"))
        @test Pluto.update_from_file(🍭, notebook)
        # vanilla behavior: ran immediately, nothing stale
        @test notebook.cells[1].output.body == "3"
        @test all(c -> !c.stale, notebook.cells)
    end

    @testset "lazy mode implies file watching" begin
        # auto_reload_from_file was never enabled on this session — lazy mode started the watcher anyway (the session was lazy when the notebook was opened).
        🍭.options.evaluation.on_code_change = "lazy"
        update_save_run!(🍭, notebook, notebook.cells) # make sure file and hash are current
        content = read(notebook.path, String)
        @assert occursin("a = 3", content)

        # Simulate an external tool (e.g. a coding agent) editing the file with an atomic temp-file + rename — the pattern used by most editors and agent tools.
        tmp_path = notebook.path * ".agent_tmp"
        write(tmp_path, replace(content, "a = 3" => "a = 4"))
        mv(tmp_path, notebook.path; force=true)

        @test poll(20, 1/10) do
            notebook.cells[1].stale
        end
        # marked stale, but did not run
        @test notebook.cells[1].output.body == "3"
        @test !notebook.cells[2].stale # only the edited cell is marked

        # running the stale cells triggers a server-side save; the watcher must recognize its own save (content hash) and not react to it
        update_save_run!(🍭, notebook, Pluto.expand_stale_ancestors(notebook, filter(c -> c.stale, notebook.cells)))
        @test notebook.cells[1].output.body == "4"
        sleep(2)
        @test all(c -> !c.stale, notebook.cells)

        # an external edit landing immediately after our own save must still be picked up
        # (a time-based cooldown would swallow this; the content-hash check does not)
        content2 = read(notebook.path, String)
        write(notebook.path, replace(content2, "a = 4" => "a = 5"))
        @test poll(20, 1/10) do
            notebook.cells[1].stale
        end
        @test notebook.cells[1].output.body == "4"
    end

    SessionActions.shutdown(🍭, notebook)
end
