// app/voice/dock.ts — the call, always within reach.
//
// While you are live in a room, a small dock floats under the header on EVERY
// face: the room's name (a tap opens its sheet) and the same controls the sheet
// carries — talk, camera, share, and a plain red leave. Nothing about hanging up
// depends on which face you are on, whether the sidebar is open, or whether
// anyone has a camera on; the floating video stage comes and goes with video,
// the dock comes and goes with the call.
//
// It starts under the header and goes where you put it: drag it by the room's
// name and it stays there (as a fraction of the window, so it survives a resize
// and a different screen), a double-tap on the name sends it home. It is one more
// surface for voice/room.ts's controls and owns no call state.
import { effect } from '../reactive.js';
import { esc } from '../template.js';
import { readJSON, writeJSON, forget } from '../store.js';
import { makeDraggable } from '../drag.js';
import { liveRoom, mountRoomControls, openRoom } from './room.js';
import { roomLabel } from './room-model.js';
import { K } from "../keys.js";
const KEY = K.dockPos;
/** Start the dock: it stands while `liveRoom()` names a room. */
export function initLiveDock() {
    let dock = null;
    let unmount = null;
    let drag = null;
    let standingFor = "";
    const takeDown = () => {
        if (unmount) {
            unmount();
            unmount = null;
        }
        if (drag) {
            drag.dispose();
            drag = null;
        }
        if (dock) {
            dock.remove();
            dock = null;
        }
    };
    effect(() => {
        const room = liveRoom();
        if (room === standingFor)
            return;
        standingFor = room;
        takeDown();
        if (!room)
            return;
        const el = document.createElement("div");
        el.id = "livedock";
        el.setAttribute("role", "region");
        el.setAttribute("aria-label", "live call");
        el.innerHTML = `<span class="dockname" title="open the room — drag to move, double-tap to put back">● ${esc(roomLabel(room))}</span>`
            + `<span class="dockctl"></span>`;
        document.body.appendChild(el);
        dock = el;
        // both children are written one line up
        const name = el.querySelector(".dockname");
        const ctl = el.querySelector(".dockctl");
        const d = makeDraggable({
            handle: name, target: el,
            onEnd: (p) => writeJSON(KEY, { fx: p.x / innerWidth, fy: p.y / innerHeight }),
        });
        drag = d;
        name.onclick = () => { if (!d.justDragged())
            openRoom(room); };
        name.ondblclick = () => { d.reset(); forget(KEY); };
        const saved = readJSON(KEY, null);
        if (saved && Number.isFinite(saved.fx) && Number.isFinite(saved.fy))
            d.place(saved.fx * innerWidth, saved.fy * innerHeight);
        unmount = mountRoomControls(ctl, room);
    });
}
