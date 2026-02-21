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
import { create } from "elm-websocket-manager";

const app = Elm.Main.init({ node: document.getElementById("app") });
create({ wsOut: app.ports.wsOut, wsIn: app.ports.wsIn });
```

## Usage

```elm
import WebSocketManager as WS exposing (Event(..), CloseCode(..))

-- Configure a connection
chatConfig : WS.Config
chatConfig =
    WS.init
        { url = "ws://example.com/chat"
        , protocols = []
        , reconnect = Just WS.defaultReconnect
        }

-- Bind to a port — returns a record of command functions
chatWs : WS.WebSocket Msg
chatWs = WS.withPorts chatConfig wsOut

-- Use it: no socket IDs to thread
update msg model =
    case msg of
        Connect    -> ( model, chatWs.open )
        Send text  -> ( model, chatWs.send text )
        Disconnect -> ( model, chatWs.close )

-- Subscribe to events from all connections
subscriptions _ =
    WS.onEvent wsIn [ chatConfig ] GotWsEvent
```

Handle events by pattern matching:

```elm
case msg of
    GotWsEvent (Ok { event }) ->
        case event of
            Opened              -> -- connected
            MessageReceived data -> -- got a message
            Closed info          -> -- closed (info.code, info.reason, info.wasClean)
            Reconnecting info    -> -- reconnecting (info.attempt, info.nextDelayMs)
            Reconnected          -> -- back online
            ReconnectFailed      -> -- gave up
            Error message        -> -- error

    GotWsEvent (Err _) ->
        -- decode error
```

## Multiple connections

Each `Config` produces its own `WebSocket msg` record. Dispatch events by comparing configs:

```elm
notifWs = WS.withPorts notifConfig wsOut

subscriptions _ =
    WS.onEvent wsIn [ chatConfig, notifConfig ] GotWsEvent

-- In update:
GotWsEvent (Ok { config, event }) ->
    if config == chatConfig then
        handleChat event model
    else if config == notifConfig then
        handleNotif event model
    else
        ( model, Cmd.none )
```

## Reconnection

Reconnection is opt-in. Pass `reconnect = Just WS.defaultReconnect` to enable exponential backoff with jitter. Customize the config or pass `Nothing` to disable:

```elm
{ maxRetries = Nothing       -- Nothing = infinite
, initialDelayMs = 1000
, maxDelayMs = 30000
, backoffMultiplier = 2.0
, jitter = True
, skipCodes = [ Normal, PolicyViolation ]
}
```

The JS side manages timers. Elm receives `Reconnecting`, `Reconnected`, and `ReconnectFailed` events for UI updates.

## Close codes

RFC 6455 codes are a union type — no magic integers:

```elm
chatWs.closeWith Normal "session ended"

case event of
    Closed { code } ->
        case code of
            Normal          -> -- clean shutdown
            AbnormalClosure -> -- network dropped
            CustomCode 4001 -> -- app-specific
            _               -> -- other
```

## Connection state helper

Track connection state with `ConnectionState` and `connectionStateFromEvent`:

```elm
case WS.connectionStateFromEvent event of
    Just newState -> { model | chatState = newState }
    Nothing       -> model
```

## Advanced: typed commands

For logging, testing, or command pipelines, use the `Command` type directly instead of `withPorts`:

```elm
WS.encode chatConfig Open |> wsOut
WS.encode chatConfig (Send "hello") |> wsOut
WS.encode chatConfig (CloseWith Normal "done") |> wsOut
```

## Example

See [`example/`](example/) for a runnable echo client with connection state UI and reconnection.

## License

BSD-3-Clause
