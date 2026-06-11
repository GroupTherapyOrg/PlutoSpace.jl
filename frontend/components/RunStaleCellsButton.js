import { html } from "../imports/Preact.js"
import { cl } from "../common/ClassTable.js"
import { t } from "../common/lang.js"

/**
 * A floating notice (same pattern as `UndoDelete`) that appears when any cells are stale: their code — or an upstream cell's code — changed without running, e.g. because the notebook file was edited by an external tool while `on_code_change = "lazy"`. The link runs all stale cells in one reactive run.
 *
 * @param {{
 *  notebook: import("./Editor.js").NotebookData,
 *  on_run: (cell_ids: Array<string>) => void,
 * }} props
 * */
export const RunStaleCellsButton = ({ notebook, on_run }) => {
    const stale_cell_ids = notebook.cell_order.filter((cell_id) => notebook.cell_results[cell_id]?.stale ?? false)
    const hidden = stale_cell_ids.length === 0

    let text = t("t_stale_cells", { count: stale_cell_ids.length })

    return html`
        <nav id="run_stale_cells" inert=${hidden} class=${cl({ hidden })}>
            ${text} (<a
                href="#"
                onClick=${(e) => {
                    e.preventDefault()
                    on_run(stale_cell_ids)
                }}
                ><strong>${t("t_run_stale_cells_link")}</strong></a
            >)
        </nav>
    `
}
