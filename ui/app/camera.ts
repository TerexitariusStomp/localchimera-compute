// app/camera.ts — the device's camera, held open on a video element.
//
// One mechanism for everything that looks through the camera: the label screen
// reads a symbol from it (scan.ts) and the photo screen takes a still from it
// (capture.ts). The stream belongs to the Camera, not to a video element: the
// sheet redraws its card when a line changes, and the viewfinder follows the
// stream onto the new element (`attach`) without the camera closing. No frame
// leaves the device from here.

/** Whether this browser can open a camera at all. */
export const canStream = (): boolean => !!navigator.mediaDevices?.getUserMedia;

/** A camera held open. */
export interface Camera {
  /** Show the camera in VIDEO, replacing the element it was showing. */
  attach(video: HTMLVideoElement): Promise<void>;
  /** The frame on show now, as a JPEG; null when nothing is showing yet. */
  frame(): Promise<Blob | null>;
  /** Let the camera go. Safe to call twice. */
  stop(): void;
}

/**
 * Open the rear camera (the front one where there is no rear). Null when it
 * cannot be had; ONSTATE then hears why, in words a face can show:
 * "the camera is kept to you" when the person said no, else "no camera here".
 */
export async function openCamera(onState: (words: string) => void = () => {}): Promise<Camera | null> {
  if (!canStream()) { onState("no camera here"); return null; }
  let stream: MediaStream | null;
  try {
    stream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: "environment" }, audio: false });
  } catch (e) {
    onState(e instanceof DOMException && e.name === "NotAllowedError" ? "the camera is kept to you" : "no camera here");
    return null;
  }
  let shown: HTMLVideoElement | null = null;
  return {
    async attach(video) {
      if (!stream) return;
      if (shown && shown !== video) shown.srcObject = null;     // the element the card replaced lets the stream go
      shown = video;
      video.srcObject = stream;
      video.muted = true;
      video.setAttribute("playsinline", "");
      await video.play().catch(() => { /* a paused preview still feeds a frame */ });
    },
    frame() {
      const v = shown;
      if (!stream || !v || v.readyState < 2 || !v.videoWidth) return Promise.resolve(null);
      const c = document.createElement("canvas");
      c.width = v.videoWidth; c.height = v.videoHeight;
      c.getContext("2d")?.drawImage(v, 0, 0);
      return new Promise(resolve => c.toBlob(b => resolve(b), "image/jpeg", 0.92));
    },
    stop() {
      stream?.getTracks().forEach(t => t.stop());
      stream = null;
      if (shown) shown.srcObject = null;
      shown = null;
    },
  };
}
