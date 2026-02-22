# elm-websocket-manager

Type-safe WebSocket management for Elm 0.19 with reconnection support.

Provides Elm types, encoders, decoders, and a companion JS module. You declare two ports and wire them in; everything else is typed Elm code.

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

-- Bind to the command port — returns a record of command functions
chatWs : WS.WebSocket Msg
chatWs = WS.bind chatConfig wsOut

-- Use it
update msg model =
    case msg of
        Connect           -> ( model, chatWs.open )
        Send text         -> ( model, chatWs.send text )
        Disconnect        -> ( model, chatWs.close )
        GotChatEvent ...  -> ...
        WsDecodeError ... -> ...

-- Subscribe to events
subscriptions _ =
    WS.onEvent wsIn [ ( chatConfig, GotChatEvent ) ] WsDecodeError
```

Handle events by pattern matching:

```elm
case msg of
    GotChatEvent (Ok event) ->
        case event of
            WS.Opened               -> -- connected
            WS.MessageReceived data -> -- got a message
            WS.Closed info          -> -- closed {code, reason, wasClean}
            WS.Reconnecting info    -> -- reconnecting {attempt, nextDelayMs, maxRetries}
            WS.Reconnected          -> -- back online
            WS.ReconnectFailed      -> -- gave up
            WS.Error message        -> -- error

    GotChatEvent (Err _) ->
        -- event decode error

    WsDecodeError _ ->
        -- missing or unmatched websocket id
```

## Multiple connections

Each `Config` produces its own `WebSocket msg` record. Pair each config with a dedicated message constructor:

```elm
chatWs = WS.bind chatConfig wsOut
notifWs = WS.bind notifConfig wsOut

subscriptions _ =
    WS.onEvent wsIn
        [ ( chatConfig, GotChatEvent )
        , ( notifConfig, GotNotifEvent )
        ]
        WsDecodeError

-- In update:
GotChatEvent (Ok event) ->
    handleChat event model

GotNotifEvent (Ok event) ->
    handleNotif event model
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

The JS side manages timers. Elm receives `Reconnecting`, `Reconnected`, and `ReconnectFailed` events for UI updates. If you need to change the reconnection config at runtime, create a new connection with different parameters instead.

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

For logging, testing, or command pipelines, use the `Command` type directly instead of `bind`:

```elm
WS.encode chatConfig WS.Open |> wsOut
WS.encode chatConfig (WS.Send "hello") |> wsOut
WS.encode chatConfig (WS.CloseWith (Just WS.Normal) (Just "done")) |> wsOut
```

## Example

See [`example/`](https://github.com/mpizenberg/elm-websocket-manager/tree/main/example) for a runnable echo client with connection state UI and reconnection.

## License

BSD-3-Clause
