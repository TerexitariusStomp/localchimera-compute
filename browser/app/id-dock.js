// app/id-dock.ts — the identity door, seated in the express bar.
//
// The #idrow element (a round user icon with its connection dot, and the
// modal it opens — tabs/social/id.ts) is moved in from the header and sits at
// the pill's left end, ahead of the microphone and the camera: who you are
// and whether the commune is reachable are part of the expression, the first
// of its round controls.
let wired = false;
export function initIdDock() {
    if (wired)
        return;
    wired = true;
    const mic = document.getElementById("sbmic");
    const idrow = document.getElementById("idrow");
    if (!mic || !idrow)
        return;
    mic.before(idrow);
}
