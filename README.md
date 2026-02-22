# elm-websocket-manager

Type-safe WebSocket management for Elm 0.19 with reconnection and binary (Bytes) support.

Provides Elm types, encoders, decoders, and a companion JS module. You declare two ports and wire them in; everything else is typed Elm code. Binary data transfers bypass JSON entirely via an XHR monkeypatch, giving zero-cost `Bytes` interop.
On a recent laptop, a round trip of 100MB witch an "echo" websocket takes about 1 second.

API docs (temporary): https://elm-doc-preview.netlify.app/?repo=mpizenberg/elm-websocket-manager&version=elm-doc-preview

## Install

**Elm** (not yet published — use as a local package or git dependency):

```json
"source-directories": [ "src", "path/to/elm-websocket-manager/src" ]
```

**JS** companion:

```sh
npm install elm-websocket-manager
```

## Setup

Declare two ports:

```elm
port wsOut : WS.CommandPort msg
port wsIn : WS.EventPort msg
```

Wire them in JS:

```javascript
import * as wsm from "elm-websocket-manager";

const app = Elm.Main.init({ node: document.getElementById("app") });
wsm.init({ wsOut: app.ports.wsOut, wsIn: app.ports.wsIn });
```

## Usage

```elm
import WebSocketManager as WS

-- Configure a connection
chatConfig : WS.Config
chatConfig =
    WS.init "ws://example.com/chat"

-- Bind to the command port — returns a record of command functions.
-- The GotChatEvent constructor is used internally to route binary XHR results
-- through your normal event handling.
chatWs : WS.WebSocket Msg
chatWs =
    WS.bind chatConfig wsOut GotChatEvent

-- Use it
update msg model =
    case msg of
        GotChatEvent (Ok event) ->
            WS.withBinaryPolling chatConfig GotChatEvent handleChat event model
        GotChatEvent (Err _)    -> ...
        WsDecodeError _         -> ...
        Connect                 -> ( model, chatWs.open )
        SendText text           -> ( model, chatWs.sendText text )
        SendBinary bytes        -> ( model, chatWs.sendBytes bytes )
        Disconnect              -> ( model, chatWs.close )

-- Subscribe to events
subscriptions _ =
    WS.onEvent wsIn [ ( chatConfig, GotChatEvent ) ] WsDecodeError
```

Handle events by pattern matching:

```elm
handleChat : WS.Event -> Model -> ( Model, Cmd Msg )
handleChat event model =
    case event of
        WS.Opened                  -> -- connected
        WS.MessageReceived data    -> -- got a text message
        WS.BinaryReceived bytes    -> -- got a binary message (Bytes)
        WS.Closed info             -> -- closed {code, reason, wasClean}
        WS.Reconnecting info       -> -- reconnecting {attempt, nextDelayMs, maxRetries}
        WS.Reconnected             -> -- back online
        WS.ReconnectFailed         -> -- gave up
        WS.Error message           -> -- error
        WS.NoOp                    -> ( model, Cmd.none )
```

## Binary (Bytes) support

Binary messages are sent and received as Elm `Bytes` with zero JSON overhead. Under the hood, an XHR monkeypatch intercepts requests to a fake `.localhost` URL, routing `ArrayBuffer` data directly between Elm's `Http` kernel and the WebSocket.
Big thanks to `@lue-bird` for the explanation in his [Bytes-through-port benchmark](https://github.com/lue-bird/elm-bytes-ports-benchmark/tree/main?tab=readme-ov-file#http-taskport).

**Sending** is fire-and-forget via `chatWs.sendBytes`:

```elm
chatWs.sendBytes myBytes
```

**Receiving** is automatic when you wrap your event handler with `withBinaryPolling`. It starts a long-poll on `Opened` and `Reconnected`, and re-polls after each `BinaryReceived`:

```elm
GotChatEvent (Ok event) ->
    WS.withBinaryPolling chatConfig GotChatEvent handleChat event model
```

Binary messages arrive as `WS.BinaryReceived bytes` — handle them just like `WS.MessageReceived`.

`WS.NoOp` is an internal plumbing event produced when a fire-and-forget binary send completes or when the binary long-poll is terminated by a connection close. It carries no information and can be safely ignored:

```elm
WS.NoOp -> ( model, Cmd.none )
```

For low-level use without `bind`, the standalone `WS.sendBytes` function gives full control over the result:

```elm
WS.sendBytes chatConfig payload GotChatEvent
--> Cmd Msg
```

## Multiple connections

Each `Config` produces its own `WebSocket msg` record. Pair each config with a dedicated message constructor:

```elm
chatWs = WS.bind chatConfig wsOut GotChatEvent
notifWs = WS.bind notifConfig wsOut GotNotifEvent

subscriptions _ =
    WS.onEvent wsIn
        [ ( chatConfig, GotChatEvent )
        , ( notifConfig, GotNotifEvent )
        ]
        WsDecodeError

-- In update:
GotChatEvent (Ok event) ->
    WS.withBinaryPolling chatConfig GotChatEvent handleChat event model

GotNotifEvent (Ok event) ->
    WS.withBinaryPolling notifConfig GotNotifEvent handleNotif event model
```

## Reconnection

`WS.init` enables reconnection by default with `WS.defaultReconnect`. Use `WS.initWithParams` for full control — pass `reconnect = Nothing` to disable, or customize the config:

```elm
{ maxRetries = Nothing       -- Nothing = infinite
, initialDelayMs = 1000
, maxDelayMs = 30000
, backoffMultiplier = 2.0
, jitter = True
, skipCodes = [ WS.Normal, WS.PolicyViolation ]
}
```

The JS side manages timers. Elm receives `Reconnecting`, `Reconnected`, and `ReconnectFailed` events for UI updates. Binary long-polling restarts automatically on reconnect when using `withBinaryPolling`.

## Close codes

RFC 6455 codes are a union type:

```elm
chatWs.closeWith (Just WS.Normal) (Just "session ended")

case event of
    WS.Closed { code } ->
        case code of
            WS.Normal          -> -- clean shutdown
            WS.AbnormalClosure -> -- network dropped
            WS.CustomCode 4001 -> -- app-specific
            _                  -> -- other
```

## Connection state helper

Track connection state with `ConnectionState` and `connectionStateFromEvent`:

```elm
case WS.connectionStateFromEvent event of
    Just newState -> { model | chatState = newState }
    Nothing       -> model
```

## Advanced: typed commands

For logging, testing, or command pipelines, use the `Command` type directly instead of `bind`.
You can’t trace Bytes data exchange with the `Command` type though.

```elm
WS.encode chatConfig WS.Open |> wsOut
WS.encode chatConfig (WS.SendText "hello") |> wsOut
WS.encode chatConfig (WS.CloseWith (Just WS.Normal) (Just "done")) |> wsOut
```

## Example

See [`example/`](https://github.com/mpizenberg/elm-websocket-manager/tree/main/example) for a runnable echo client with text and binary messaging, connection state UI, and reconnection.

## Comparison with other packages

Compared with [billstclair/elm-websocket-client](https://package.elm-lang.org/packages/billstclair/elm-websocket-client/latest/) and [kageurufu/elm-websockets](https://package.elm-lang.org/packages/kageurufu/elm-websockets/latest/).

### Approach

| | **elm-websocket-manager** | **billstclair/elm-websocket-client** | **kageurufu/elm-websockets** |
|---|---|---|---|
| Architecture | Ports + XHR monkeypatch | Ports (via elm-port-funnel) | Ports |

### Core capabilities

| | **elm-websocket-manager** | **billstclair/elm-websocket-client** | **kageurufu/elm-websockets** |
|---|---|---|---|
| Text messages | Yes | Yes | Yes |
| Binary (Bytes) data | Yes (zero-JSON overhead) | No | No |
| Multiple connections | Yes (URL-based) | Yes (key-based, supports same URL) | Yes (name-based) |
| Reconnection | Exponential backoff with jitter, configurable maxRetries, delays, skipCodes | Exponential backoff, per-connection on/off | No |
| Connection state tracking | Yes (Connecting/Connected/Disconnected/Reconnecting/Failed) | Partial (isConnected check) | No |
| Close codes (RFC 6455) | Full enum with custom codes | Yes (ClosedCode type) | No |
| Keep-alive | No | Yes | No |
| Testing simulator | No | Yes | No |
| Metadata on open | No | No | Yes (Dict String String) |

### Developer experience

| | **elm-websocket-manager** | **billstclair/elm-websocket-client** | **kageurufu/elm-websockets** |
|---|---|---|---|
| Exposed modules | 1 | 1 | 4 |
| Elm dependencies | 5 (core, json, bytes, http, url) | 5 (core, json, port-funnel, decode-pipeline, list-extra) | 2 (core, json) |
| Setup boilerplate | Low (2 ports, 1 JS init call) | High (copy PortFunnels.elm, load 2 JS files, manage State in Model) | Low (2 ports, 1 JS init call) |
| API style | `bind` returns a record (`ws.open`, `ws.sendText`, ...) | Factory functions (`makeOpen`, `makeSend`) + manual port send | `withPorts` returns a record (`socket.open`, `socket.send`, ...) |
| State management | Handled by JS layer | Must store State in Model manually | Handled by JS layer |
| Event handling | Single `Event` sum type with `onEvent` routing | `Response` sum type processed in update | `EventHandlers` record with per-event callbacks |

### Features we don't implement

- **Keep-alive:** Trivially achieved by ignoring incoming events in the message handler. A dedicated mode would only save a pattern match branch.
- **Testing simulator:** Can be worked around by testing your pure update logic with hand-crafted `Event` values. Worth considering in a future version.
- **Metadata on open:** The browser `WebSocket` API does not support custom headers. kageurufu's metadata is stored client-side and echoed back in events but never sent to the server. For auth, pass tokens as URL query parameters or in the first message after connecting.
- **Multiple connections to same URL:** Uncommon need. If required, append a discriminator query parameter (e.g., `?session=1`) to produce distinct URLs.

## License

BSD-3-Clause
