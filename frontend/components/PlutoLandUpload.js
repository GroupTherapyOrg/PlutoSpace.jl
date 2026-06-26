import { html, useEffect, useState } from "../imports/Preact.js"
import _ from "../imports/lodash-es.js"

//@ts-ignore
import { useDialog } from "../common/useDialog.js"
import { useEventListener } from "../common/useEventListener.js"
import { t, th } from "../common/lang.js"
import { exportNotebookDesktop, WarnForVisisblePasswords } from "./ExportBanner.js"
import { useMillisSinceTruthy } from "./RunArea.js"
import { cl } from "../common/ClassTable.js"

/** Add the &offline_bundle=true query parameter to a URL string */
export const with_offline_bundle_query = (/** @type {string | URL | undefined} */ url) => {
    if (!url) return url
    if (url?.toString().startsWith("data:")) return url
    const u = new URL(url, window.location.href)
    u.searchParams.set("offline_bundle", "true")
    return u.toString()
}

/**
 * @param {{
 *  notebook_id: String,
 * }} props
 * */
export const PlutoLandUpload = ({ notebook_id }) => {
    const [dialog_ref, open, close, _toggle] = useDialog()
    const [open_event_detail, set_open_event_detail] = useState(/** @type {Record<string, unknown>} */ ({}))
    const { download_url, download_filename } = open_event_detail

    useEventListener(
        window,
        "open pluto html export",
        (/** @type {CustomEvent} */ e) => {
            set_open_event_detail(e.detail)
            open()
        },
        [open, set_open_event_detail]
    )

    const [upload_flow_state, set_upload_flow_state] = useState("waiting")
    const [plutoland_data, set_plutoland_data] = useState(/** @type Record<string, unknown> */ ({}))

    const [upload_progress, set_upload_progress] = useState(0)

    // Show some fake progress while the server is processing the upload
    const [fake_progressing, set_fake_progressing] = useState(false)
    const fake_progress = useMillisSinceTruthy(fake_progressing)
    useEffect(() => {
        if (fake_progressing && fake_progress) {
            const y = 1.0 - Math.exp(-2 * (fake_progress / 1000))
            set_upload_progress(Math.min(0.7 + y * 0.3, 1.0))
        }
    }, [fake_progress, fake_progressing])

    const on_plutoland_upload = async () => {
        try {
            set_upload_flow_state("generating")
            set_upload_progress(0)

            // We download the HTML export **without** offline bundle. This makes the file much smaller so there is less work for pluto.land.
            const notebook_response = await fetch(String(download_url))
            const notebook_blob = await notebook_response.blob()

            set_upload_flow_state("uploading")
            set_upload_progress(0.1)
            const response = await upload_to_plutoland(notebook_blob, (progress) => {
                set_upload_progress(0.1 + progress * 0.6)
                if (progress >= 1.0) set_fake_progressing(true)
            })

            console.log(response)

            if (response.status === 200) {
                const data = JSON.parse(response.response)
                console.log(data)
                set_plutoland_data(data)
                set_upload_flow_state("success")
            } else {
                set_upload_flow_state("error: Upload failed")
            }
        } catch (error) {
            set_upload_flow_state("error: " + error)
        }
    }

    const prog = html`<progress class="ple-plutoland-progress" max="100" value=${upload_progress * 100}>${Math.round(upload_progress * 100)}%</progress>`

    const is_recording = open_event_detail.is_recording ?? false

    return html`<dialog ref=${dialog_ref} class="export-html-dialog">
        <div class="ple-download ple-option">
            <p>${th(is_recording ? "t_plutoland_download_description_recording" : "t_plutoland_download_description")}</p>
            <div class="ple-bigbutton-container">
                <a
                    class="ple-bigbutton"
                    href=${String(download_url)}
                    target="_blank"
                    download=${download_filename ?? ""}
                    onClick=${(e) => {
                        exportNotebookDesktop(e, 1, notebook_id)
                        close()
                    }}
                >
                    ${th("t_plutoland_download")} ${InlineIonicon("download-outline", { inlineMargin: true })}
                </a>
            </div>
        </div>
        ${/* PlutoSpace: "Share to pluto.land" (upload to the Pluto team's hosting service) has been
            removed — no connections to pluto.land. The local HTML-export download above stays. */ null}
        <div class="final"><button onClick=${close}>${t("t_frontmatter_cancel")}</button></div>
    </dialog>`
}

export const InlineIonicon = (icon_name, { inlineMargin = false } = {}) => {
    return html`<span class=${cl({ "ionicon-icon": true, "ionicon-icon-margin": inlineMargin })} data-icon=${icon_name} data-inline="true"></span>`
}

// PlutoSpace: uploading to pluto.land (the Pluto team's hosting service) has been removed.
/** @returns {Promise<XMLHttpRequest>} */
const upload_to_plutoland = (/** @type {File | Blob} */ filesource, onprogress = (val, xhr) => {}) =>
    Promise.reject(new Error("Upload to pluto.land is not available in PlutoSpace."))
