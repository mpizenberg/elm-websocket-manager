// elm-websocket-manager companion JS module.
// See DESIGN.md for the full wire protocol specification.

// ============================================================
// XHR Monkeypatch (module-level, before init)
// ============================================================

const XHR_PREFIX = "https://elm-ws-bytes.localhost/.xhrhook";
const xhrHandlers = {};

function installXhrMonkeypatch() {
  if (XMLHttpRequest.prototype._elmWsPatched) return;
  XMLHttpRequest.prototype._elmWsPatched = true;

  const origOpen = XMLHttpRequest.prototype.open;
  const origSend = XMLHttpRequest.prototype.send;
  const origSetRequestHeader = XMLHttpRequest.prototype.setRequestHeader;
  const origAbort = XMLHttpRequest.prototype.abort;

  // -- open: intercept XHR_PREFIX URLs, skip native open --
  XMLHttpRequest.prototype.open = function (method, url) {
    if (typeof url === "string" && url.startsWith(XHR_PREFIX)) {
      this._elmWs = {
        url,
        method,
        headers: {},
        aborted: false,
      };
      // Override responseType on this instance since we skip native open()
      // (native responseType getter behavior varies in UNSENT state)
      let storedResponseType = "";
      Object.defineProperty(this, "responseType", {
        get() { return storedResponseType; },
        set(v) { storedResponseType = v; },
        configurable: true,
      });
    } else {
      origOpen.apply(this, arguments);
    }
  };

  // -- setRequestHeader: store if intercepted, pass through otherwise --
  XMLHttpRequest.prototype.setRequestHeader = function (name, value) {
    if (this._elmWs) {
      this._elmWs.headers[name] = value;
    } else {
      origSetRequestHeader.apply(this, arguments);
    }
  };

  // -- send: dispatch to handler if intercepted --
  XMLHttpRequest.prototype.send = function (body) {
    if (!this._elmWs) {
      origSend.apply(this, arguments);
      return;
    }
    const xhr = this;
    const meta = this._elmWs;
    // Route = everything after XHR_PREFIX + "/"
    const route = meta.url.slice(XHR_PREFIX.length + 1);
    const handler = xhrHandlers[route];
    if (!handler) {
      console.error("[elm-ws] No XHR handler for route:", route);
      return;
    }
    handler(
      { method: meta.method, url: meta.url, headers: meta.headers, body },
      function resolve(status, responseBody) {
        if (meta.aborted) return;
        fabricateResponse(xhr, status, responseBody);
      }
    );
  };

  // -- abort: flag as aborted if intercepted --
  XMLHttpRequest.prototype.abort = function () {
    if (this._elmWs) {
      this._elmWs.aborted = true;
    } else {
      origAbort.apply(this, arguments);
    }
  };
}

// Fabricate a complete XHR response on an intercepted instance.
// Uses Object.defineProperty because the XHR never went through
// native open(), so its built-in properties are in UNSENT state.
function fabricateResponse(xhr, status, responseBody) {
  Object.defineProperty(xhr, "status", {
    get: () => status, configurable: true,
  });
  Object.defineProperty(xhr, "statusText", {
    get: () => (status === 200 ? "OK" : ""), configurable: true,
  });
  Object.defineProperty(xhr, "responseURL", {
    get: () => xhr._elmWs.url, configurable: true,
  });
  Object.defineProperty(xhr, "response", {
    get: () => responseBody, configurable: true,
  });
  Object.defineProperty(xhr, "readyState", {
    get: () => 4, configurable: true,
  });
  xhr.getAllResponseHeaders = () => "";

  // Async dispatch to match the XHR contract (load event is never synchronous)
  setTimeout(() => {
    if (xhr._elmWs.aborted) return;
    xhr.dispatchEvent(new Event("load"));
  }, 0);
}

// ============================================================
// WebSocket Manager
// ============================================================

export function init(ports) {
  installXhrMonkeypatch();

  const sockets = new Map();

  ports.wsOut.subscribe((cmd) => {
    switch (cmd.tag) {
      case "open":
        openSocket(cmd);
        break;
      case "send":
        sendText(cmd);
        break;
      case "close":
        closeSocket(cmd);
        break;
    }
  });

  function openSocket({ id, protocols, reconnect }) {
    const existing = sockets.get(id);
    if (existing) {
      existing.intentionalClose = true;
      clearTimeout(existing.reconnectTimer);
      resolvePendingRecv(existing, 499);
      existing.ws.close(1000, "replaced");
    }

    const ws = new WebSocket(id, protocols || []);
    ws.binaryType = "arraybuffer";
    const entry = {
      ws,
      url: id,
      protocols: protocols || [],
      reconnect: reconnect || null,
      retries: existing ? existing.retries : 0,
      intentionalClose: false,
      reconnectTimer: null,
      pendingRecv: null,
      recvBuffer: [],
    };
    sockets.set(id, entry);
    registerBinaryHandlers(id, entry);

    ws.onopen = () => {
      entry.retries = 0;
      emit({ tag: "opened", id });
    };

    ws.onmessage = (e) => {
      if (typeof e.data === "string") {
        emit({ tag: "message", id, data: e.data });
      } else if (e.data instanceof ArrayBuffer) {
        if (entry.pendingRecv) {
          const pending = entry.pendingRecv;
          entry.pendingRecv = null;
          pending.resolve(200, e.data);
        } else {
          entry.recvBuffer.push(e.data);
        }
      }
    };

    ws.onclose = (e) => {
      resolvePendingRecv(entry, 499);
      emit({
        tag: "closed",
        id,
        code: e.code,
        reason: e.reason,
        wasClean: e.wasClean,
      });

      if (!entry.intentionalClose && entry.reconnect) {
        scheduleReconnect(id, entry, e.code);
      }
    };

    ws.onerror = () => {
      emit({ tag: "error", id, message: "WebSocket error" });
    };
  }

  function scheduleReconnect(id, entry, closeCode) {
    const config = entry.reconnect;

    // Check skip codes
    if (config.skipCodes && config.skipCodes.includes(closeCode)) {
      return;
    }

    // Check max retries
    if (config.maxRetries !== null && entry.retries >= config.maxRetries) {
      emit({ tag: "reconnectFailed", id });
      return;
    }

    entry.retries++;

    let delay =
      config.initialDelayMs *
      Math.pow(config.backoffMultiplier, entry.retries - 1);
    delay = Math.min(delay, config.maxDelayMs);
    if (config.jitter) {
      delay += Math.random() * delay * 0.3;
    }
    delay = Math.round(delay);

    emit({
      tag: "reconnecting",
      id,
      attempt: entry.retries,
      nextDelayMs: delay,
      maxRetries: config.maxRetries,
    });

    entry.reconnectTimer = setTimeout(() => {
      // Reset intentionalClose for the new connection attempt
      entry.intentionalClose = false;
      openSocket({
        id,
        protocols: entry.protocols,
        reconnect: config,
      });
    }, delay);
  }

  function sendText({ id, data }) {
    const entry = sockets.get(id);
    if (entry && entry.ws.readyState === WebSocket.OPEN) {
      entry.ws.send(data);
    }
  }

  function closeSocket({ id, code, reason }) {
    const entry = sockets.get(id);
    if (entry) {
      entry.intentionalClose = true;
      clearTimeout(entry.reconnectTimer);
      resolvePendingRecv(entry, 499);
      entry.ws.close(code || 1000, reason || "");
    }
  }

  function registerBinaryHandlers(id, entry) {
    const encodedId = encodeURIComponent(id);

    // Send handler: Elm POSTs bytes, we forward to WebSocket
    xhrHandlers["ws-send/" + encodedId] = (req, resolve) => {
      if (entry.ws.readyState === WebSocket.OPEN && req.body) {
        // req.body is a DataView (Elm's internal Bytes representation)
        // WebSocket.send() accepts ArrayBufferView, DataView qualifies
        entry.ws.send(req.body);
        resolve(200, new ArrayBuffer(0));
      } else {
        resolve(503, new ArrayBuffer(0));
      }
    };

    // Receive handler: Elm long-polls, we hold until binary message arrives
    xhrHandlers["ws-recv/" + encodedId] = (req, resolve) => {
      if (entry.recvBuffer.length > 0) {
        // Buffered message available, resolve immediately
        resolve(200, entry.recvBuffer.shift());
      } else {
        // Hold the resolve callback for the next binary message
        entry.pendingRecv = { resolve };
      }
    };
  }

  function resolvePendingRecv(entry, status) {
    if (entry.pendingRecv) {
      const pending = entry.pendingRecv;
      entry.pendingRecv = null;
      pending.resolve(status, new ArrayBuffer(0));
    }
  }

  function emit(event) {
    ports.wsIn.send(event);
  }
}
