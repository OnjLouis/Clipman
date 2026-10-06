"use strict";
globalThis.ClipmanLinks = {
  target(row) {
    if (row.rich || row.truncated) return null;
    const text = row.text.trim();
    if (/[\r\n\u0000-\u001f\u007f]/.test(text)) return null;
    const match = /^(https?:\/\/\S+)(?:\s+link)?$/i.exec(text);
    if (!match) return null;
    try {
      const url = new URL(match[1]);
      return url.hostname && ["http:", "https:"].includes(url.protocol) ? match[1] : null;
    } catch (_) { return null; }
  }
};
