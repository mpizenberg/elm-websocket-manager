# elm-websocket-manager

Type-safe WebSocket management for Elm 0.19 with reconnection and binary (Bytes) support.

Provides Elm types, encoders, decoders, and a companion JS module. You declare two ports and wire them in; everything else is typed Elm code. Binary data transfers bypass JSON entirely via an XHR monkeypatch, giving zero-cost `Bytes` interop.

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

## License

BSD-3-Clause
