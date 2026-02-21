# elm-websocket-manager example

A WebSocket echo client demonstrating the full `elm-websocket-manager` API:
config-based identity, the `withPorts` convenience layer, `onEvent` subscription,
connection state tracking, and automatic reconnection with lifecycle events.

## Setup

```sh
npm install
```

## Run

All commands below are run from this `example/` directory.

Build the Elm app:

```sh
npm run build
```

Start the echo server in one terminal:

```sh
npm run server
```

Start the static file server in another terminal:

```sh
npm run serve
```

Then open <http://localhost:3000>.

## What to try

- **Send messages** — type in the input and press Enter or click Send. The echo server reflects each message back.
- **Disconnect** — click Disconnect and watch the close event appear in the log.
- **Reconnection** — stop the echo server (Ctrl-C) while connected. The app shows `Reconnecting` events with attempt count and backoff delay. Restart the server and it reconnects automatically, emitting a `Reconnected` event.
- **Failed reconnection** — stop the server and wait. With `defaultReconnect` (infinite retries), it keeps trying. Edit `echoConfig` in `Main.elm` to set `maxRetries = Just 3` and rebuild to see `ReconnectFailed` after 3 attempts.

## Files

| File             | Description                                           |
| ---------------- | ----------------------------------------------------- |
| `src/Main.elm`   | Port module — echo client using `WebSocketManager`    |
| `index.html`     | HTML shell wiring Elm ports to `websocket-manager.js` |
| `echo-server.js` | Minimal Node.js WebSocket echo server on port 8080    |
| `serve.js`       | Static file server for development                    |
| `elm.json`       | Application config pulling `../src` for the package   |
