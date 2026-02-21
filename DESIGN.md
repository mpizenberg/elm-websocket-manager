# elm-websocket-manager: Design Report

## Goal

Design a type-safe, structured-ports WebSocket package for Elm 0.19. The package provides Elm types, encoders, decoders, and a companion JS module. The user declares two ports and wires them in; everything else is typed Elm code.

Key design priorities:
- **Config-based identity** — each connection is a self-contained value, no ID threading
- **Typed commands** — `Open`, `Send`, `Close` as an Elm custom type with exposed variants
- **Typed events** — a single `Event` type with a provided decoder, not ad-hoc `Value` parsing
- **Structured close codes** — an Elm type for RFC 6455 close codes, not raw integers
- **Reconnection control** — configurable from Elm, with lifecycle events reported back
- **Global subscription** — single `onEvent` function dispatches events by `Config`
- **Publishable as a package** — no `port module`, uses the `withPorts` pattern

---

## Architecture Overview

```
┌─────────────────────────────────────────┐
│  Elm Application                        │
│                                         │
│  ┌───────────────────────────────────┐  │
│  │  elm-websocket-manager (package)  │  │
│  │                                   │  │
│  │  Types: Config, Command, Event   │  │
│  │  Encoding: encode                │  │
│  │  Decoding: eventDecoder, onEvent │  │
│  │  Convenience: withPorts          │  │
│  └──────────┬───────────┬────────────┘  │
│             │           │               │
│          encode      onEvent            │
│             │           │               │
│  ┌──────────▼───────────▼────────────┐  │
│  │  User's port module               │  │
│  │  port wsOut : Value -> Cmd msg    │  │
│  │  port wsIn : (Value -> msg) -> Sub│  │
│  └──────────┬───────────┬────────────┘  │
└─────────────┼───────────┼───────────────┘
              │           │
     ┌────────▼───────────▼────────┐
     │  websocket-manager.js       │
     │                             │
     │  Manages WebSocket objects  │
     │  Reconnection state machine │
     │  Event forwarding           │
     └─────────────────────────────┘
```

Elm packages cannot declare ports. So the package exposes type aliases for the port signatures and the user satisfies them:

```elm
-- In the package
type alias CommandPort msg = Json.Encode.Value -> Cmd msg
type alias EventPort msg = (Json.Decode.Value -> msg) -> Sub msg
```

```elm
-- In the user's port module
port wsOut : WebSocketManager.CommandPort msg
port wsIn : WebSocketManager.EventPort msg
```

---

## Module Structure

Everything lives in a single `WebSocketManager` module. The exposing list is grouped with comments — most users only need the first group:

```elm
module WebSocketManager exposing
    ( -- Quick start: configure, wire, use
      Config, Params, init
    , WebSocket, withPorts, CommandPort, EventPort
    , WsEvent, onEvent
    -- Events (pattern match on these)
    , Event(..), CloseInfo, ReconnectInfo
    -- Close codes
    , CloseCode(..), closeCodeToInt, closeCodeFromInt
    -- Reconnection
    , ReconnectConfig, defaultReconnect
    -- Connection state (optional helper)
    , ConnectionState(..), connectionStateFromEvent
    -- Advanced: typed commands
    , Command(..), encode, eventDecoder
    )
```

Most users' import:

```elm
import WebSocketManager as WS exposing (Event(..), CloseCode(..))
```

They create a `Config` with `WS.init`, get a `WebSocket msg` record from `WS.withPorts`, subscribe with `WS.onEvent`, and pattern-match on events. They never touch `Command` or `encode`.

**File layout:**

```
elm-websocket-manager/
  src/
    WebSocketManager.elm          -- Single module: types, encoders, decoders, convenience
  js/
    websocket-manager.js          -- JS companion module
  package.json                    -- npm package for the JS module
  elm.json                        -- Elm package definition
```

---

## Quick Start: Convenience Layer

This is the primary API. Most users only need `Config`, `withPorts`, and `onEvent`.

### Config & Params

A `Config` represents a WebSocket connection's configuration. It is opaque — created once via `init` and passed to `withPorts` and `onEvent`:

```elm
type alias Params =
    { url : String
    , protocols : List String
    , reconnect : Maybe ReconnectConfig
    }

type Config -- opaque

init : Params -> Config
```

The URL serves as the wire-level identity for the connection. Each `Config` must have a unique URL.

```elm
chatConfig : WS.Config
chatConfig =
    WS.init
        { url = "ws://example.com/chat"
        , protocols = []
        , reconnect = Just WS.defaultReconnect
        }

notifConfig : WS.Config
notifConfig =
    WS.init
        { url = "ws://example.com/notifications"
        , protocols = []
        , reconnect = Nothing
        }
```

### withPorts (commands)

`withPorts` binds a `Config` to a command port, returning a record of ready-to-use command functions:

```elm
type alias WebSocket msg =
    { open : Cmd msg
    , send : String -> Cmd msg
    , close : Cmd msg
    , closeWith : CloseCode -> String -> Cmd msg
    , configureReconnect : Maybe ReconnectConfig -> Cmd msg
    }

withPorts : Config -> CommandPort msg -> WebSocket msg
```

No socket IDs to thread — each `WebSocket msg` record is bound to its connection:

```elm
chatWs : WS.WebSocket Msg
chatWs = WS.withPorts chatConfig wsOut

notifWs : WS.WebSocket Msg
notifWs = WS.withPorts notifConfig wsOut

update msg model =
    case msg of
        ConnectChat ->
            ( model, chatWs.open )

        SendChat text ->
            ( model, chatWs.send text )

        Disconnect ->
            ( model, chatWs.close )
```

### onEvent (global subscription)

A single subscription handles events from all connections. Each event is paired with the `Config` it came from:

```elm
type alias WsEvent =
    { config : Config, event : Event }

onEvent :
    EventPort msg
    -> List Config
    -> (Result Decode.Error WsEvent -> msg)
    -> Sub msg
```

Internally, `onEvent` tries each config's decoder (matching by URL). If the event matches a config, it produces `Ok { config, event }`. If no config matches or the JSON is malformed, it produces `Err`.

```elm
subscriptions : Model -> Sub Msg
subscriptions _ =
    WS.onEvent wsIn [ chatConfig, notifConfig ] GotWsEvent
```

**Single connection** — no dispatch needed, the config can be ignored:

```elm
subscriptions _ =
    WS.onEvent wsIn [ chatConfig ] GotWsEvent

update msg model =
    case msg of
        GotWsEvent (Ok { event }) ->
            case event of
                MessageReceived data -> ...
                Closed info -> ...
                _ -> ( model, Cmd.none )

        GotWsEvent (Err _) ->
            ( model, Cmd.none )
```

**Multiple connections** — dispatch by comparing configs:

```elm
update msg model =
    case msg of
        GotWsEvent (Ok { config, event }) ->
            if config == chatConfig then
                handleChatEvent event model
            else if config == notifConfig then
                handleNotifEvent event model
            else
                ( model, Cmd.none )

        GotWsEvent (Err _) ->
            ( model, Cmd.none )
```

Config equality uses Elm's structural equality — two configs created from the same `Params` are equal.

---

## Core Types

### Command

`Command` variants are fully exposed. Users can construct them directly or use `withPorts` for convenience:

```elm
type Command
    = Open
    | Send String
    | Close
    | CloseWith CloseCode String
    | ConfigureReconnect (Maybe ReconnectConfig)
```

**Encoding** requires a `Config` to associate the command with a connection:

```elm
encode : Config -> Command -> Value
```

Serializes to the JSON protocol the JS side expects:

```json
{ "tag": "open", "id": "ws://example.com/chat", "protocols": [], "reconnect": null }
{ "tag": "send", "id": "ws://example.com/chat", "data": "hello" }
{ "tag": "close", "id": "ws://example.com/chat" }
{ "tag": "close", "id": "ws://example.com/chat", "code": 1000, "reason": "done" }
{ "tag": "configureReconnect", "id": "ws://example.com/chat", "reconnect": { ... } }
```

**Direct usage** (without `withPorts`):

```elm
update msg model =
    case msg of
        ConnectChat ->
            ( model, WS.encode chatConfig Open |> wsOut )

        SendChat text ->
            ( model, WS.encode chatConfig (Send text) |> wsOut )
```

### Event

```elm
type Event
    = Opened
    | MessageReceived String
    | Closed CloseInfo
    | Error String
    | Reconnecting ReconnectInfo
    | Reconnected
    | ReconnectFailed -- max retries exhausted
```

Events carry no connection identifier — the `WsEvent` wrapper (from `onEvent`) pairs each event with the `Config` it belongs to.

```elm
type alias CloseInfo =
    { code : CloseCode
    , reason : String
    , wasClean : Bool
    }

type alias ReconnectInfo =
    { attempt : Int
    , nextDelayMs : Int
    , maxRetries : Maybe Int
    }
```

**Decoder** (config-specific — only decodes events matching this config's URL):

```elm
eventDecoder : Config -> Decoder Event
```

Decodes the JSON protocol from the JS side:

```json
{ "tag": "opened", "id": "ws://example.com/chat" }
{ "tag": "message", "id": "ws://example.com/chat", "data": "hello" }
{ "tag": "closed", "id": "ws://example.com/chat", "code": 1000, "reason": "done", "wasClean": true }
{ "tag": "error", "id": "ws://example.com/chat", "message": "connection failed" }
{ "tag": "reconnecting", "id": "ws://example.com/chat", "attempt": 2, "nextDelayMs": 4000, "maxRetries": 10 }
{ "tag": "reconnected", "id": "ws://example.com/chat" }
{ "tag": "reconnectFailed", "id": "ws://example.com/chat" }
```

The decoder first checks that the `id` field matches the config's URL. If it doesn't, the decoder fails — this is how `onEvent` filters events per connection.

### CloseCode

RFC 6455 defines standard close codes. Exposing them as a union type prevents magic numbers:

```elm
type CloseCode
    = Normal              -- 1000: Normal closure
    | GoingAway           -- 1001: Endpoint going away (page navigation)
    | ProtocolError       -- 1002: Protocol error
    | UnsupportedData     -- 1003: Unsupported data type
    | NoStatus            -- 1005: No status code present (never sent in frame)
    | AbnormalClosure     -- 1006: No close frame received (never sent in frame)
    | InvalidPayload      -- 1007: Invalid frame payload data
    | PolicyViolation     -- 1008: Policy violation
    | MessageTooBig       -- 1009: Message too big
    | MissingExtension    -- 1010: Client expected extension server didn't negotiate
    | InternalError       -- 1011: Unexpected server condition
    | ServiceRestart      -- 1012: Server restarting
    | TryAgainLater       -- 1013: Server temporarily unavailable
    | CustomCode Int      -- 3000-4999: Application-defined codes
```

```elm
closeCodeToInt : CloseCode -> Int
closeCodeFromInt : Int -> CloseCode
```

**Usage:**

```elm
-- Closing with a typed code
chatWs.closeWith Normal "session ended"

-- Pattern matching on close events
case event of
    Closed { code } ->
        case code of
            Normal -> -- clean shutdown
            AbnormalClosure -> -- network dropped
            ServiceRestart -> -- server restarting, will reconnect
            PolicyViolation -> -- kicked by server
            CustomCode 4001 -> -- app-specific: authentication expired
            _ -> -- other
```

### ReconnectConfig

```elm
type alias ReconnectConfig =
    { maxRetries : Maybe Int -- Nothing = infinite retries
    , initialDelayMs : Int
    , maxDelayMs : Int
    , backoffMultiplier : Float
    , jitter : Bool -- add random jitter to prevent thundering herds
    , skipCodes : List CloseCode -- do not reconnect on these codes
    }

defaultReconnect : ReconnectConfig
defaultReconnect =
    { maxRetries = Nothing
    , initialDelayMs = 1000
    , maxDelayMs = 30000
    , backoffMultiplier = 2.0
    , jitter = True
    , skipCodes = [ Normal, PolicyViolation ]
    }
```

**Reconnection is opt-in.** By default, `init` with `reconnect = Nothing` does not reconnect. The user must explicitly provide a config:

```elm
chatConfig =
    WS.init
        { url = "ws://example.com/chat"
        , protocols = []
        , reconnect = Just WS.defaultReconnect
        }
```

**Why opt-in:** The old `elm-lang/websocket` silently reconnected, which broke stateful protocols. Making it explicit forces the user to think about what happens on reconnection (re-authenticate? re-subscribe? discard stale state?).

**Lifecycle events during reconnection:**

```
Closed  ──>  Reconnecting (attempt 1, delay 1000ms)
             Reconnecting (attempt 2, delay 2000ms)
             Reconnecting (attempt 3, delay 4000ms)
             ──>  Reconnected  (or ReconnectFailed if max retries exhausted)
```

The `Reconnecting` event tells the app "I'm about to try again in N ms" — giving the app a chance to update UI (show "reconnecting..." spinner). The `Reconnected` event tells the app "connection is live again, re-authenticate now."

**Disabling reconnection for specific close codes:**

Some close codes mean "don't reconnect" (e.g., the server explicitly kicked the client). The `skipCodes` field controls this. Default: `[ Normal, PolicyViolation ]`. The JS side checks the close code against this list before scheduling a reconnection attempt.

### ConnectionState (optional helper)

The package provides a simple type for tracking connection states:

```elm
type ConnectionState
    = Connecting
    | Connected
    | Disconnected CloseInfo
    | ReconnectingState ReconnectInfo
    | Failed -- reconnect gave up
```

And a helper to derive the new state from an event:

```elm
connectionStateFromEvent : Event -> Maybe ConnectionState
connectionStateFromEvent event =
    case event of
        Opened -> Just Connected
        Closed info -> Just (Disconnected info)
        Reconnecting info -> Just (ReconnectingState info)
        Reconnected -> Just Connected
        ReconnectFailed -> Just Failed
        _ -> Nothing
```

Usage — each connection is a separate field in the model:

```elm
case WS.connectionStateFromEvent event of
    Just newState ->
        { model | chatState = newState }

    Nothing ->
        model
```

---

## Wire Protocol

The full JSON protocol between Elm and JS. The `id` field is the connection's URL, derived from the `Config`.

### Commands (Elm → JS)

| Tag | Fields | Description |
|---|---|---|
| `open` | `id`, `protocols`, `reconnect` | Open a new connection (`id` is the URL) |
| `send` | `id`, `data` | Send a text message |
| `close` | `id`, `code?`, `reason?` | Close a connection |
| `configureReconnect` | `id`, `reconnect` | Update reconnection config for an existing connection |

### Events (JS → Elm)

| Tag | Fields | Description |
|---|---|---|
| `opened` | `id` | Connection established |
| `message` | `id`, `data` | Text message received |
| `closed` | `id`, `code`, `reason`, `wasClean` | Connection closed |
| `error` | `id`, `message` | Error occurred |
| `reconnecting` | `id`, `attempt`, `nextDelayMs`, `maxRetries` | Reconnection scheduled |
| `reconnected` | `id` | Reconnection succeeded |
| `reconnectFailed` | `id` | All retries exhausted |

---

## JS Side Design

The JS module is a self-contained manager that the user initializes once:

```javascript
// websocket-manager.js
export function create(ports) {
  const sockets = new Map();

  ports.wsOut.subscribe((cmd) => {
    switch (cmd.tag) {
      case "open":     openSocket(cmd); break;
      case "send":     sendText(cmd);   break;
      case "close":    closeSocket(cmd); break;
      case "configureReconnect": configureReconnect(cmd); break;
    }
  });

  function openSocket({ id, protocols, reconnect }) {
    // id is the URL — serves as both the connection target and the map key
    const existing = sockets.get(id);
    if (existing) {
      existing.intentionalClose = true;
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
      // Binary support will be added later
    };

    ws.onclose = (e) => {
      emit({
        tag: "closed", id,
        code: e.code, reason: e.reason, wasClean: e.wasClean,
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

    let delay = config.initialDelayMs
      * Math.pow(config.backoffMultiplier, entry.retries - 1);
    delay = Math.min(delay, config.maxDelayMs);
    if (config.jitter) {
      delay += Math.random() * delay * 0.3; // ±30% jitter
    }
    delay = Math.round(delay);

    emit({
      tag: "reconnecting", id,
      attempt: entry.retries,
      nextDelayMs: delay,
      maxRetries: config.maxRetries,
    });

    entry.reconnectTimer = setTimeout(() => {
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
```

**User initialization:**

```javascript
import { Elm } from "./Main.elm";
import * as WebSocketManager from "elm-websocket-manager";

const app = Elm.Main.init({ node: document.getElementById("app") });
WebSocketManager.create({ wsOut: app.ports.wsOut, wsIn: app.ports.wsIn });
```

---

## Full Usage Example

```elm
port module Main exposing (main)

import Browser
import Json.Decode as Decode
import WebSocketManager as WS exposing (CloseCode(..), Event(..))


-- PORTS

port wsOut : WS.CommandPort msg
port wsIn : WS.EventPort msg


-- SETUP

chatConfig : WS.Config
chatConfig =
    WS.init
        { url = "ws://example.com/chat"
        , protocols = []
        , reconnect = Just WS.defaultReconnect
        }

chatWs : WS.WebSocket Msg
chatWs = WS.withPorts chatConfig wsOut


-- MODEL

type alias Model =
    { messages : List String
    , draft : String
    , chatState : WS.ConnectionState
    }

init : () -> ( Model, Cmd Msg )
init _ =
    ( { messages = []
      , draft = ""
      , chatState = WS.Connecting
      }
    , chatWs.open
    )


-- UPDATE

type Msg
    = GotWsEvent (Result Decode.Error WS.WsEvent)
    | DraftChanged String
    | SendClicked
    | DisconnectClicked

update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        GotWsEvent (Ok { event }) ->
            case event of
                MessageReceived data ->
                    ( { model | messages = data :: model.messages }, Cmd.none )

                Reconnected ->
                    -- Connection restored — re-authenticate or re-subscribe here
                    ( { model | chatState = WS.Connected }, Cmd.none )

                _ ->
                    case WS.connectionStateFromEvent event of
                        Just newState ->
                            ( { model | chatState = newState }, Cmd.none )

                        Nothing ->
                            ( model, Cmd.none )

        GotWsEvent (Err _) ->
            ( model, Cmd.none )

        DraftChanged text ->
            ( { model | draft = text }, Cmd.none )

        SendClicked ->
            ( { model | draft = "" }, chatWs.send model.draft )

        DisconnectClicked ->
            ( model, chatWs.close )


-- SUBSCRIPTIONS

subscriptions : Model -> Sub Msg
subscriptions _ =
    WS.onEvent wsIn [ chatConfig ] GotWsEvent
```

---

## Design Decisions

### 1. Config-Based Identity

Instead of an opaque `SocketId` that users thread through every command and extract from every event, each connection is represented by a `Config` value created once and bound to a `WebSocket msg` record. The URL serves as the wire-level identity.

**What this prevents:**

```elm
-- Old SocketId approach — easy to pass the wrong ID:
ws.send notifSocket "hello"  -- meant to send to chatSocket

-- Config approach — each WebSocket record is bound to its connection:
chatWs.send "hello"   -- can only send to chat
notifWs.send "hello"  -- can only send to notifications
```

The identity is established at definition time (`WS.init` + `WS.withPorts`) and never appears in command or event handling code.

**Limitation:** Each `Config` must have a unique URL. Multiple independent connections to the exact same URL are not supported. This covers the vast majority of use cases. If needed later, a `name` field can be added to `Params` to disambiguate.

### 2. Exposed Command Variants

The `Command` type exposes all its constructors. Users who need the typed command layer construct variants directly:

```elm
WS.encode chatConfig Open |> wsOut
WS.encode chatConfig (Send "hello") |> wsOut
WS.encode chatConfig (CloseWith Normal "done") |> wsOut
```

This keeps the API surface minimal — no separate constructor functions that mirror the variants. The `withPorts` convenience layer is the primary API for daily use; the typed `Command` layer is for advanced use cases like logging, testing, or building command pipelines.

### 3. Global Subscription Model

All connections share a single port pair. Events arrive through one `wsIn` port. Rather than per-WebSocket subscriptions (which produce spurious decode errors for non-matching events), a single `onEvent` function takes a list of all configs and dispatches correctly:

```elm
WS.onEvent wsIn [ chatConfig, notifConfig ] GotWsEvent
```

Internally, `onEvent` tries each config's decoder (matching by URL). Exactly one config matches per event, producing `Ok { config, event }`. If none match or the JSON is malformed, it produces `Err`.

For single-connection apps, the config can be ignored when handling events. For multi-connection apps, users dispatch with `if config == chatConfig then ...`.

### 4. Reconnection: JS-Managed vs Elm-Managed

**JS-managed (chosen):** Reconnection timers and state live in JS. Elm receives `Reconnecting`/`Reconnected`/`ReconnectFailed` events and tracks state. Configuration is sent from Elm at init time.

**Elm-managed alternative:** Elm receives `Closed` events, decides whether to reconnect, computes backoff delays using `Process.sleep`, and sends a new `Open` command. All logic is pure Elm.

The Elm-managed approach is more "Elm-like" but has drawbacks:
- `Process.sleep` produces a `Cmd` that goes through the Elm runtime message queue — adding latency
- The reconnection state machine must live in the user's `Model` and `update` — significant boilerplate
- If the tab is suspended (browser throttling), Elm timers may fire late or batch unpredictably
- Every user must implement the same reconnection logic

**Decision:** JS-managed with Elm-configurable parameters. The JS side handles the timer mechanics; the Elm side decides the policy.

---

## Comparison with Existing Packages

| Feature | elm-websocket-manager | kageurufu/elm-websockets | billstclair/elm-websocket-client | bburdette/websocket |
|---|---|---|---|---|
| Config-based identity | Yes (opaque Config) | No (String) | No (String or Key) | No (String) |
| Typed Command type | Yes (exposed variants) | Partial (functions → Value) | No (opaque Message) | No (raw JSON) |
| Typed Event type | Yes (custom type + decoder) | Partial (EventHandlers record) | Yes (Response type) | Minimal (Data/Error) |
| CloseCode type | Yes (union type) | No (raw Int) | No (raw Int) | No |
| Reconnection | Yes (configurable, with events) | No | Yes (built-in backoff) | No |
| withPorts pattern | Yes (per-connection records) | Yes | No (PortFunnels) | No |
| Global subscription | Yes (single onEvent) | No | No | No |
| Publishable as package | Yes | Yes | Yes | Yes |
| Connection state helper | Yes (optional) | No | No | No |
| Reconnection events | Yes (Reconnecting/Reconnected/Failed) | No | No | No |

---

## Summary

The elm-websocket-manager design provides meaningful type safety improvements over existing solutions:

1. **Config-based identity** eliminates socket ID threading — each connection is a self-contained record
2. **`Event` custom type** without connection IDs keeps pattern matching clean
3. **`CloseCode` union type** replaces magic integers with self-documenting constructors
4. **`WsEvent` with global subscription** dispatches events cleanly across multiple connections
5. **Typed reconnection config** with lifecycle events gives the app full visibility into connection state
6. **`withPorts` convenience layer** as the primary API eliminates all encoding boilerplate

Most users create configs, call `withPorts`, subscribe with `onEvent`, and work entirely with `Cmd msg` and `Event`. The typed `Command(..)` + `encode` layer is available in the same module for advanced use cases. The companion JS module handles WebSocket lifecycle and reconnection, keeping Elm code focused on application logic.
