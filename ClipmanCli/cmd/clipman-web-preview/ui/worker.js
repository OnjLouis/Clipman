"use strict";
let loaded = false;
self.clipmanResult = raw => postMessage(JSON.parse(raw));
self.clipmanReady = () => { loaded = true; postMessage({ ready: true }); };
self.onmessage = event => {
  if (loaded) self.clipmanExecute(JSON.stringify(event.data));
};
(async () => {
  try {
    importScripts("./wasm_exec.js");
    const go = new Go();
    const result = await WebAssembly.instantiateStreaming(fetch("./client.wasm", { cache: "no-store", credentials: "omit" }), go.importObject);
    await go.run(result.instance);
  } catch (_) { postMessage({ startupError: "Could not start the browser client." }); }
})();
