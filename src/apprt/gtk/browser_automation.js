// Runs only in Colm's named WebKit script world, never in the page's world.
// No script-message handler or other native/terminal bridge is registered.
globalThis.__colmApi = {
  snapshot(generation) {
    const old = globalThis.__colmAutomation;
    const state = { generation, next: old?.next ?? 1, refs: new Map() };
    globalThis.__colmAutomation = state;
    const elements = [];
    const visit = (root) => {
      for (const element of root.querySelectorAll("*")) {
        if (element.shadowRoot) visit(element.shadowRoot);
        if (elements.length >= 5000) return;
        if (
          !element.matches(
            'a[href],button,input,textarea,select,[role],[contenteditable="true"],[tabindex]',
          )
        )
          continue;
        const style = getComputedStyle(element);
        if (
          !element.getClientRects().length ||
          style.visibility === "hidden" ||
          style.display === "none"
        )
          continue;
        const ref = "e" + state.next++;
        state.refs.set(ref, element);
        const labels = element.labels
          ? Array.from(element.labels, (label) => label.innerText).join(" ")
          : "";
        const labelledBy = (element.getAttribute("aria-labelledby") || "")
          .split(/\s+/)
          .map((id) => document.getElementById(id)?.textContent || "")
          .join(" ")
          .trim();
        elements.push({
          ref,
          tag: element.tagName.toLowerCase(),
          role: element.getAttribute("role") || "",
          name: (
            element.getAttribute("aria-label") ||
            labelledBy ||
            labels ||
            element.innerText ||
            element.getAttribute("placeholder") ||
            element.getAttribute("title") ||
            ""
          )
            .trim()
            .slice(0, 2048),
          value:
            element.type === "password"
              ? ""
              : String(element.value ?? "").slice(0, 8192),
          disabled: !!element.disabled,
        });
      }
    };
    visit(document);
    return {
      generation,
      uri: location.href,
      title: document.title,
      text: (document.body?.innerText || "").slice(0, 262144),
      elements,
    };
  },
  element(generation, ref) {
    const state = globalThis.__colmAutomation;
    const element =
      state?.generation === generation ? state.refs.get(ref) : null;
    if (!element?.isConnected)
      throw new Error("stale_reference: take a new snapshot");
    if (element.disabled || element.getAttribute("aria-disabled") === "true")
      throw new Error("element_disabled");
    return element;
  },
  click(generation, ref) {
    const element = this.element(generation, ref);
    element.scrollIntoView({ block: "center", inline: "nearest" });
    element.focus();
    if (typeof element.click !== "function")
      throw new Error("element_not_clickable");
    element.click();
    return { generation, ref, clicked: true };
  },
  upload(generation, ref) {
    const element = this.element(generation, ref);
    if (!(element instanceof HTMLInputElement) || element.type !== "file")
      throw new Error("element_not_file_input");
    element.scrollIntoView({ block: "center", inline: "nearest" });
    element.focus();
    element.click();
    return {
      generation,
      ref,
      files: Array.from(element.files || [], ({ name, size, type }) => ({
        name,
        size,
        type,
      })),
      uploaded: true,
    };
  },
  fill(generation, ref, value) {
    const element = this.element(generation, ref);
    if (element.readOnly) throw new Error("element_readonly");
    element.focus();
    if (
      element instanceof HTMLInputElement ||
      element instanceof HTMLTextAreaElement ||
      element instanceof HTMLSelectElement
    ) {
      if (
        element.type === "file" ||
        element.type === "checkbox" ||
        element.type === "radio"
      )
        throw new Error("element_not_text_editable");
      const prototype =
        element instanceof HTMLTextAreaElement
          ? HTMLTextAreaElement.prototype
          : element instanceof HTMLSelectElement
            ? HTMLSelectElement.prototype
            : HTMLInputElement.prototype;
      Object.getOwnPropertyDescriptor(prototype, "value").set.call(
        element,
        value,
      );
    } else if (element.isContentEditable) {
      element.textContent = value;
    } else {
      throw new Error("element_not_editable");
    }
    element.dispatchEvent(
      new Event("input", { bubbles: true, composed: true }),
    );
    element.dispatchEvent(new Event("change", { bubbles: true }));
    return { generation, ref, filled: true };
  },
  get(generation, ref) {
    const element = this.element(generation, ref);
    const rect = element.getBoundingClientRect();
    return {
      generation,
      ref,
      tag: element.tagName.toLowerCase(),
      text: (element.innerText || element.textContent || "").slice(0, 262144),
      value: element.type === "password" ? "" : String(element.value ?? "").slice(0, 262144),
      html: element.outerHTML.slice(0, 262144),
      attributes: Object.fromEntries(
        Array.from(element.attributes, ({ name, value }) => [name, value.slice(0, 8192)]),
      ),
      bounds: { x: rect.x, y: rect.y, width: rect.width, height: rect.height },
    };
  },
  find(query) {
    const text = String(query).toLocaleLowerCase();
    const matches = [];
    for (const element of document.querySelectorAll("*")) {
      if (matches.length >= 500) break;
      const content = (element.innerText || element.textContent || "").trim();
      if (!content || !content.toLocaleLowerCase().includes(text)) continue;
      if (element.children.length && Array.from(element.children).some(
        (child) => (child.innerText || child.textContent || "").toLocaleLowerCase().includes(text),
      )) continue;
      matches.push({
        tag: element.tagName.toLowerCase(),
        text: content.slice(0, 8192),
      });
    }
    return { query, matches };
  },
  async wait(query, timeout) {
    const deadline = performance.now() + timeout;
    while (performance.now() <= deadline) {
      const result = this.find(query);
      if (result.matches.length) return result;
      await new Promise((resolve) => setTimeout(resolve, 50));
    }
    throw new Error("wait_timeout");
  },
  frames() {
    const frames = [];
    const visit = (win, parent) => {
      for (let index = 0; index < win.frames.length && frames.length < 500; index++) {
        const child = win.frames[index];
        const id = frames.length;
        try {
          frames.push({
            id,
            parent,
            name: child.name || "",
            uri: child.location.href,
            title: child.document.title,
            accessible: true,
          });
          visit(child, id);
        } catch {
          frames.push({ id, parent, name: child.name || "", uri: "", title: "", accessible: false });
        }
      }
    };
    visit(window, null);
    return { frames };
  },
  script(source) {
    const value = (0, eval)(String(source));
    return { value: value === undefined ? null : value };
  },
  style(css) {
    const element = document.createElement("style");
    element.dataset.colmStyle = "true";
    element.textContent = String(css);
    (document.head || document.documentElement).appendChild(element);
    return { styles: document.querySelectorAll("style[data-colm-style]").length };
  },
  annotate(generation, ref, text) {
    const element = this.element(generation, ref);
    const marker = document.createElement("div");
    const rect = element.getBoundingClientRect();
    marker.dataset.colmAnnotation = "true";
    marker.textContent = String(text);
    Object.assign(marker.style, {
      position: "fixed",
      zIndex: "2147483647",
      left: `${Math.max(0, rect.left)}px`,
      top: `${Math.max(0, rect.top - 24)}px`,
      padding: "2px 6px",
      color: "white",
      background: "#b42318",
      borderRadius: "4px",
      font: "12px sans-serif",
      pointerEvents: "none",
    });
    document.documentElement.appendChild(marker);
    return { generation, ref, annotated: true };
  },
  clearAnnotations() {
    document.querySelectorAll("[data-colm-annotation]").forEach((element) => element.remove());
    return { cleared: true };
  },
  stateExport() {
    return {
      origin: location.origin,
      cookies: document.cookie,
      localStorage: Object.fromEntries(
        Array.from({ length: localStorage.length }, (_, index) => {
          const key = localStorage.key(index);
          return [key, localStorage.getItem(key)];
        }),
      ),
      sessionStorage: Object.fromEntries(
        Array.from({ length: sessionStorage.length }, (_, index) => {
          const key = sessionStorage.key(index);
          return [key, sessionStorage.getItem(key)];
        }),
      ),
    };
  },
  stateImport(state) {
    if (!state || typeof state !== "object")
      throw new Error("invalid_state");
    if (state.origin !== location.origin)
      throw new Error("state_origin_mismatch");
    const restore = (storage, values) => {
      if (!values || typeof values !== "object" || Array.isArray(values))
        throw new Error("invalid_state");
      storage.clear();
      for (const [key, value] of Object.entries(values))
        storage.setItem(key, String(value));
    };
    restore(localStorage, state.localStorage);
    restore(sessionStorage, state.sessionStorage);
    for (const cookie of String(state.cookies || "").split(/;\s*/))
      if (cookie) document.cookie = cookie;
    return this.stateExport();
  },
  select(generation, ref, value) {
    const element = this.element(generation, ref);
    if (!(element instanceof HTMLSelectElement))
      throw new Error("element_not_select");
    element.value = value;
    element.dispatchEvent(new Event("input", { bubbles: true }));
    element.dispatchEvent(new Event("change", { bubbles: true }));
    return { generation, ref, value: element.value, selected: true };
  },
  press(generation, ref, key) {
    const element = this.element(generation, ref);
    element.focus();
    for (const type of ["keydown", "keypress", "keyup"])
      element.dispatchEvent(new KeyboardEvent(type, { key, bubbles: true, composed: true }));
    return { generation, ref, key, pressed: true };
  },
};
