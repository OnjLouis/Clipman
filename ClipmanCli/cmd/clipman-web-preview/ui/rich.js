"use strict";
globalThis.ClipmanRich = {
  clean(html, preview = false) {
    if (!DOMPurify.isSupported) throw new Error("This browser cannot safely display formatted content.");
    return DOMPurify.sanitize(html, {
      ALLOWED_TAGS: ["p", "div", "span", "br", "hr", "b", "strong", "i", "em", "u", "s", "sub", "sup", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "li", "blockquote", "pre", "code", "table", "thead", "tbody", "tfoot", "tr", "th", "td", "caption", "a", "img"],
      ALLOWED_ATTR: ["href", "src", "alt", "title", "colspan", "rowspan"],
      ADD_ATTR: (attribute, tag) => tag === "img" && ["data-clipman-image", "data-clipman-filename"].includes(attribute),
      ADD_URI_SAFE_ATTR: ["data-clipman-image", "data-clipman-filename"],
      ALLOW_DATA_ATTR: false, ALLOW_ARIA_ATTR: false,
      ALLOWED_URI_REGEXP: /^(?:https?:\/\/|data:image\/(?:png|jpeg);base64,)/i,
      FORBID_ATTR: preview ? ["href"] : [],
      RETURN_DOM_FRAGMENT: preview
    });
  },
  clipboardItem(document) {
    const data = {
      "text/plain": new Blob([document.text], {type:"text/plain"}),
      "text/html": new Blob([this.clean(document.html)], {type:"text/html"})
    };
    if (this.imageSource(document)) data["image/png"] = this.pngBlob(document);
    return new ClipboardItem(data);
  },
  imageSource(document) {
    const fragment = this.clean(document.html, true);
    const elements = [...fragment.childNodes].filter(node => node.nodeType !== Node.TEXT_NODE || node.textContent.trim());
    return elements.length === 1 && elements[0].nodeName === "IMG" ? elements[0].getAttribute("src") : null;
  },
  async pngBlob(document) {
    const source = this.imageSource(document);
    if (!source) throw new Error("No supported standalone image.");
    const [header, base64] = source.split(",");
    const bytes = Uint8Array.from(atob(base64), character=>character.charCodeAt(0));
    const blob = new Blob([bytes], {type:header === "data:image/png;base64" ? "image/png" : "image/jpeg"});
    if (blob.type === "image/png") return blob;
    const bitmap = await createImageBitmap(blob);
    try {
      if (bitmap.width > 2048 || bitmap.height > 2048) throw new Error("Image exceeds the clipboard limit.");
      const canvas = globalThis.document.createElement("canvas"); canvas.width=bitmap.width; canvas.height=bitmap.height;
      canvas.getContext("2d").drawImage(bitmap,0,0);
      return await new Promise((resolve,reject)=>canvas.toBlob(value=>value ? resolve(value) : reject(new Error("Image conversion failed.")),"image/png"));
    } finally { bitmap.close(); }
  }
};
