// elm-websocket-manager companion JS module.

import * as bridge from "elm-xhr-bytes-bridge/js/xhr-bytes-bridge.js";

export function init(ports) {
  bridge.install();

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
    bridge.handle("ws-send/" + encodedId, (req, resolve) => {
      if (entry.ws.readyState === WebSocket.OPEN && req.body) {
        // req.body is a DataView (Elm's internal Bytes representation)
        // WebSocket.send() accepts ArrayBufferView, DataView qualifies
        entry.ws.send(req.body);
        resolve(200, new ArrayBuffer(0));
      } else {
        resolve(503, new ArrayBuffer(0));
      }
    });

    // Receive handler: Elm long-polls, we hold until binary message arrives
    bridge.handle("ws-recv/" + encodedId, (req, resolve) => {
      if (entry.recvBuffer.length > 0) {
        // Buffered message available, resolve immediately
        resolve(200, entry.recvBuffer.shift());
      } else {
        // Hold the resolve callback for the next binary message
        entry.pendingRecv = { resolve };
      }
    });
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
