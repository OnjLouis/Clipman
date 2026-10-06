"use strict";
globalThis.ClipmanPaging = {
  pages(total, current) {
    const pages = new Set();
    const include = page => { if (page >= 1 && page <= total) pages.add(page); };
    for (let i = 1; i <= 3; i++) { include(i); include(total - i + 1); }
    for (let i = current - 1; i <= current + 1; i++) include(i);
    return [...pages].sort((a, b) => a - b);
  }
};
