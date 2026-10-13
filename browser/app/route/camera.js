// app/route/camera.ts — framing a box on the map, exactly.
//
// maplibre keeps a flyTo's `padding` on the camera, and a fitBounds then adds its own padding to it, so a framing that
// means its padding exactly (the box between a card above and a sheet below) first clears what is there. That is a fact
// about the library, learnt once ("Map cannot fit within canvas" is the silent failure otherwise), and it lives here
// for every framing to share — the preview's, and the overview's.
/** No room kept around the centre. */
export const NO_PADDING = { top: 0, bottom: 0, left: 0, right: 0 };
/** Clear the camera's standing padding, then frame `bounds` with `o.padding` and nothing else. */
export function fitClear(map, bounds, o) {
    map.setPadding(NO_PADDING);
    map.fitBounds(bounds, o);
}
