// app/storage-notice.ts — the device's storage refusing a write, said once.
//
// A refused write keeps its value until the tab closes and loses it at
// reload. The person is told the first time it happens in a session; the
// settings' storage section (app/storage-view.ts) carries the standing
// readout. Both read one signal, storage-health's lastFault. main.ts imports
// this for its effect.
import { effect } from "./reactive.js";
import { lastFault } from "./storage-health.js";
import { toast } from "./toast.js";
let said = false;
effect(() => {
    if (!lastFault() || said)
        return;
    said = true;
    toast("this device's storage is full or blocked — changes made now last until the page closes", "warn", { duration: 12000 });
});
