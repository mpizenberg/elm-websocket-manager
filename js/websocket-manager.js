// elm-websocket-manager companion JS module.
// See DESIGN.md for the full wire protocol specification.

export function create(ports) {
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
      case "configureReconnect":
        configureReconnect(cmd);
        break;
    }
  });

  function openSocket({ id, protocols, reconnect }) {
    const existing = sockets.get(id);
    if (existing) {
      existing.intentionalClose = true;
      clearTimeout(existing.reconnectTimer);
      existing.ws.close(1000, "replaced");
    }

    const ws = new WebSocket(id, protocols || []);
    const entry = {
      ws,
      url: id,
      protocols: protocols || [],
      reconnect: reconnect || null,
      retries: 0,
      intentionalClose: false,
      reconnectTimer: null,
    };
    sockets.set(id, entry);

    ws.onopen = () => {
      entry.retries = 0;
      emit({ tag: "opened", id });
    };

    ws.onmessage = (e) => {
      if (typeof e.data === "string") {
        emit({ tag: "message", id, data: e.data });
      }
    };

    ws.onclose = (e) => {
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
      entry.ws.close(code || 1000, reason || "");
    }
  }

  function configureReconnect({ id, reconnect }) {
    const entry = sockets.get(id);
    if (entry) {
      entry.reconnect = reconnect;
    }
  }

  function emit(event) {
    ports.wsIn.send(event);
  }
}
