// PlutoSpace: the instant-feedback widget — which loaded Firebase and posted to the Pluto team's
// "pluto-feedback" Firestore — has been removed. `init_feedback` is kept as a no-op so existing
// call sites (Editor.js) stay valid, but it loads nothing and sends nothing.
export const init_feedback = async () => {}
