// app/webbluetooth.d.ts — the Web Bluetooth surface the watch push calls.
//
// The fourth foreign API declared by hand, and the only one that is not a
// vendored library: Web Bluetooth is a BROWSER API that TypeScript's lib.dom
// does not carry, because it is not on a standards track every engine agreed
// to. Chrome-family browsers in a secure context have it and nothing else does
// — which is exactly why the watch button is built behind a
// `navigator.bluetooth` check rather than shown and then failed.
//
// Same declare-on-first-use policy as d3, maplibre and topojson: seven members,
// which is the whole of what one echo-off line over the Nordic UART REPL needs.
// Everything else Web Bluetooth offers — advertisements, descriptors,
// notifications, the whole scanning API — stays undeclared, and would be a
// compile error at a call site nobody has written.

declare global {
  /** One characteristic of a service: the thing you actually write bytes to. */
  interface BluetoothRemoteGATTCharacteristic {
    /**
     * Write WITH a response, which is the point: the acknowledgement is the
     * flow control that keeps a 20-byte-MTU device from dropping chunks.
     */
    writeValue(value: BufferSource): Promise<void>;
  }

  interface BluetoothRemoteGATTService {
    getCharacteristic(uuid: string): Promise<BluetoothRemoteGATTCharacteristic>;
  }

  interface BluetoothRemoteGATTServer {
    getPrimaryService(uuid: string): Promise<BluetoothRemoteGATTService>;
    /** Always call it — a left-open GATT link keeps the watch's radio awake. */
    disconnect(): void;
  }

  interface BluetoothDevice {
    /**
     * Present on any device the chooser returned, which is why the send does
     * not guard it: requestDevice either resolves with a connectable device or
     * rejects (NotFoundError when the user dismisses the chooser).
     */
    gatt: { connect(): Promise<BluetoothRemoteGATTServer> };
  }

  interface Bluetooth {
    /**
     * Raise the browser's own device chooser. It REJECTS with NotFoundError
     * when the user dismisses it, which is a cancellation rather than a
     * failure — the caller distinguishes the two by that name.
     */
    requestDevice(options: { filters: { services: string[] }[] }): Promise<BluetoothDevice>;
  }

  interface Navigator {
    /**
     * Optional, and the optionality is the feature. Absent everywhere but a
     * Chrome-family browser in a secure context, so reading it is how the dial
     * decides whether the watch button can exist at all.
     */
    readonly bluetooth?: Bluetooth;
  }
}

export {};
