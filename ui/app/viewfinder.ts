// app/viewfinder.ts — the camera, shown and read, held by one owner.
//
// A face that looks through the camera (the capture sheet) needs the stream
// open, shown in whichever video element the card is drawn with now, read for
// symbols, and let go when the face is. This is that owner: the camera
// (camera.ts) and at most one symbol reader (scan.ts) on it. The card redraws
// when a line of the sheet changes and the video element is new each time, so
// `follow` is called for each; calls may overlap, and the last one stands: a
// call whose turn has passed lets go of what it opened instead of leaving a
// second reader running.

import { openCamera, type Camera } from "./camera.js";
import { watchSymbols, type Scan } from "./scan.js";
import type { Seen } from "./symbols.js";

export class Viewfinder {
  /** Why there is no live camera, in words a face can show; empty while there is one, or it is opening. */
  note = "";
  private camera: Camera | null = null;
  private watcher: Scan | null = null;
  private opening: Promise<void> | null = null;
  private turn = 0;
  private done = false;

  /** ONSEEN hears each symbol read; ONCHANGE is told when the camera could not be had (the card is to be drawn without one). */
  constructor(private readonly onSeen: (s: Seen) => void, private readonly onChange: () => void) {}

  /** Whether a camera is open. */
  get live(): boolean { return this.camera !== null; }

  /** Show the camera in VIDEO (opening it the first time) and read the symbols in it. */
  async follow(video: HTMLVideoElement): Promise<void> {
    const turn = ++this.turn;
    this.watcher?.stop();
    this.watcher = null;
    if (this.done) return;
    if (!this.camera) {
      this.opening ??= this.open();
      await this.opening;
      if (!this.camera || this.done || turn !== this.turn) return;
    }
    await this.camera.attach(video);
    if (this.done || turn !== this.turn) return;
    const reader = await watchSymbols(video, this.onSeen);
    if (this.done || turn !== this.turn) { reader.stop(); return; }
    this.watcher = reader;
  }

  private async open(): Promise<void> {
    const cam = await openCamera(words => { this.note = words; });
    if (!cam) { if (!this.done) this.onChange(); return; }
    if (this.done) { cam.stop(); return; }
    this.camera = cam;
  }

  /** The frame on show, as a JPEG; null when no camera is showing one. */
  frame(): Promise<Blob | null> {
    return this.camera ? this.camera.frame() : Promise.resolve(null);
  }

  /** Let the camera and its reader go. Safe to call twice; a call in flight lets go of what it was opening. */
  stop(): void {
    this.done = true;
    this.turn++;
    this.watcher?.stop();
    this.watcher = null;
    this.camera?.stop();
    this.camera = null;
  }
}
