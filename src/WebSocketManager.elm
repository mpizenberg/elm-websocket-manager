module WebSocketManager exposing
    ( -- Quick start: configure, wire, use
      Config
    , Params
    , init
    , WebSocket
    , withPorts
    , CommandPort
    , EventPort
    , WsEvent
    , onEvent
      -- Events (pattern match on these)
    , Event(..)
    , CloseInfo
    , ReconnectInfo
      -- Close codes
    , CloseCode(..)
    , closeCodeToInt
    , closeCodeFromInt
      -- Reconnection
    , ReconnectConfig
    , defaultReconnect
      -- Connection state (optional helper)
    , ConnectionState(..)
    , connectionStateFromEvent
      -- Advanced: typed commands
    , Command(..)
    , encode
    , eventDecoder
    )

{-| Type-safe WebSocket management with reconnection support via structured ports.


# Quick Start

@docs Config, Params, init
@docs WebSocket, withPorts, CommandPort, EventPort
@docs WsEvent, onEvent


# Events

@docs Event, CloseInfo, ReconnectInfo


# Close Codes

@docs CloseCode, closeCodeToInt, closeCodeFromInt


# Reconnection

@docs ReconnectConfig, defaultReconnect


# Connection State

@docs ConnectionState, connectionStateFromEvent


# Advanced

@docs Command, encode, eventDecoder

-}

import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode



-- CONFIG


{-| Configuration for a WebSocket connection. Opaque — created via `init`.
The URL serves as the wire-level identity for the connection.
-}
type Config
    = Config Params


{-| Parameters for creating a `Config`.
-}
type alias Params =
    { url : String
    , protocols : List String
    , reconnect : Maybe ReconnectConfig
    }


{-| Create a `Config` from parameters.
-}
init : Params -> Config
init params =
    Config params



-- PORT TYPE ALIASES


{-| Type alias for the outgoing command port signature.

    port wsOut : WebSocketManager.CommandPort msg

-}
type alias CommandPort msg =
    Encode.Value -> Cmd msg


{-| Type alias for the incoming event port signature.

    port wsIn : WebSocketManager.EventPort msg

-}
type alias EventPort msg =
    (Decode.Value -> msg) -> Sub msg



-- COMMANDS


{-| Commands that can be sent to the JS WebSocket manager.
-}
type Command
    = Open
    | Send String
    | Close
    | CloseWith CloseCode String
    | ConfigureReconnect (Maybe ReconnectConfig)


{-| Encode a command for a given config, ready to be sent through a command port.
-}
encode : Config -> Command -> Encode.Value
encode (Config params) command =
    case command of
        Open ->
            Encode.object
                [ ( "tag", Encode.string "open" )
                , ( "id", Encode.string params.url )
                , ( "protocols", Encode.list Encode.string params.protocols )
                , ( "reconnect", encodeReconnect params.reconnect )
                ]

        Send data ->
            Encode.object
                [ ( "tag", Encode.string "send" )
                , ( "id", Encode.string params.url )
                , ( "data", Encode.string data )
                ]

        Close ->
            Encode.object
                [ ( "tag", Encode.string "close" )
                , ( "id", Encode.string params.url )
                ]

        CloseWith code reason ->
            Encode.object
                [ ( "tag", Encode.string "close" )
                , ( "id", Encode.string params.url )
                , ( "code", Encode.int (closeCodeToInt code) )
                , ( "reason", Encode.string reason )
                ]

        ConfigureReconnect maybeConfig ->
            Encode.object
                [ ( "tag", Encode.string "configureReconnect" )
                , ( "id", Encode.string params.url )
                , ( "reconnect", encodeReconnect maybeConfig )
                ]



-- CONVENIENCE LAYER


{-| A record of ready-to-use command functions bound to a specific connection.
-}
type alias WebSocket msg =
    { open : Cmd msg
    , send : String -> Cmd msg
    , close : Cmd msg
    , closeWith : CloseCode -> String -> Cmd msg
    , configureReconnect : Maybe ReconnectConfig -> Cmd msg
    }


{-| Bind a `Config` to a command port, returning a record of command functions.

    chatWs : WS.WebSocket Msg
    chatWs =
        WS.withPorts chatConfig wsOut

-}
withPorts : Config -> CommandPort msg -> WebSocket msg
withPorts config port_ =
    { open = port_ (encode config Open)
    , send = \data -> port_ (encode config (Send data))
    , close = port_ (encode config Close)
    , closeWith = \code reason -> port_ (encode config (CloseWith code reason))
    , configureReconnect = \rc -> port_ (encode config (ConfigureReconnect rc))
    }



-- EVENTS


{-| Events received from the JS WebSocket manager.
-}
type Event
    = Opened
    | MessageReceived String
    | Closed CloseInfo
    | Error String
    | Reconnecting ReconnectInfo
    | Reconnected
    | ReconnectFailed


{-| Information about a WebSocket close event.
-}
type alias CloseInfo =
    { code : CloseCode
    , reason : String
    , wasClean : Bool
    }


{-| Information about a reconnection attempt.
-}
type alias ReconnectInfo =
    { attempt : Int
    , nextDelayMs : Int
    , maxRetries : Maybe Int
    }


{-| A WebSocket event paired with the `Config` it belongs to.
-}
type alias WsEvent =
    { config : Config
    , event : Event
    }


{-| Decoder for events from a specific config. Only succeeds if the event's `id`
field matches the config's URL.
-}
eventDecoder : Config -> Decoder Event
eventDecoder (Config params) =
    Decode.field "id" Decode.string
        |> Decode.andThen
            (\id ->
                if id == params.url then
                    Decode.field "tag" Decode.string
                        |> Decode.andThen eventTagDecoder

                else
                    Decode.fail ("id mismatch: expected " ++ params.url ++ " but got " ++ id)
            )


eventTagDecoder : String -> Decoder Event
eventTagDecoder tag =
    case tag of
        "opened" ->
            Decode.succeed Opened

        "message" ->
            Decode.map MessageReceived
                (Decode.field "data" Decode.string)

        "closed" ->
            Decode.map3 CloseInfo
                (Decode.field "code" Decode.int |> Decode.map closeCodeFromInt)
                (Decode.field "reason" Decode.string)
                (Decode.field "wasClean" Decode.bool)
                |> Decode.map Closed

        "error" ->
            Decode.map Error
                (Decode.field "message" Decode.string)

        "reconnecting" ->
            Decode.map3 ReconnectInfo
                (Decode.field "attempt" Decode.int)
                (Decode.field "nextDelayMs" Decode.int)
                (Decode.field "maxRetries" (Decode.nullable Decode.int))
                |> Decode.map Reconnecting

        "reconnected" ->
            Decode.succeed Reconnected

        "reconnectFailed" ->
            Decode.succeed ReconnectFailed

        _ ->
            Decode.fail ("unknown event tag: " ++ tag)


{-| Subscribe to events from all listed connections through a single event port.

    subscriptions _ =
        WS.onEvent wsIn [ chatConfig, notifConfig ] GotWsEvent

-}
onEvent :
    EventPort msg
    -> List Config
    -> (Result Decode.Error WsEvent -> msg)
    -> Sub msg
onEvent port_ configs toMsg =
    port_
        (\value ->
            toMsg (tryConfigs configs value)
        )


tryConfigs : List Config -> Decode.Value -> Result Decode.Error WsEvent
tryConfigs configs value =
    case configs of
        [] ->
            Decode.decodeValue (Decode.fail "no config matched this event") value

        config :: rest ->
            case Decode.decodeValue (eventDecoder config) value of
                Ok event ->
                    Ok { config = config, event = event }

                Err _ ->
                    tryConfigs rest value



-- CLOSE CODES


{-| RFC 6455 standard close codes plus application-defined custom codes.
-}
type CloseCode
    = Normal
    | GoingAway
    | ProtocolError
    | UnsupportedData
    | NoStatus
    | AbnormalClosure
    | InvalidPayload
    | PolicyViolation
    | MessageTooBig
    | MissingExtension
    | InternalError
    | ServiceRestart
    | TryAgainLater
    | CustomCode Int


{-| Convert a `CloseCode` to its integer representation.
-}
closeCodeToInt : CloseCode -> Int
closeCodeToInt code =
    case code of
        Normal ->
            1000

        GoingAway ->
            1001

        ProtocolError ->
            1002

        UnsupportedData ->
            1003

        NoStatus ->
            1005

        AbnormalClosure ->
            1006

        InvalidPayload ->
            1007

        PolicyViolation ->
            1008

        MessageTooBig ->
            1009

        MissingExtension ->
            1010

        InternalError ->
            1011

        ServiceRestart ->
            1012

        TryAgainLater ->
            1013

        CustomCode n ->
            n


{-| Convert an integer to a `CloseCode`.
-}
closeCodeFromInt : Int -> CloseCode
closeCodeFromInt n =
    case n of
        1000 ->
            Normal

        1001 ->
            GoingAway

        1002 ->
            ProtocolError

        1003 ->
            UnsupportedData

        1005 ->
            NoStatus

        1006 ->
            AbnormalClosure

        1007 ->
            InvalidPayload

        1008 ->
            PolicyViolation

        1009 ->
            MessageTooBig

        1010 ->
            MissingExtension

        1011 ->
            InternalError

        1012 ->
            ServiceRestart

        1013 ->
            TryAgainLater

        _ ->
            CustomCode n



-- RECONNECT CONFIG


{-| Configuration for automatic reconnection.
-}
type alias ReconnectConfig =
    { maxRetries : Maybe Int
    , initialDelayMs : Int
    , maxDelayMs : Int
    , backoffMultiplier : Float
    , jitter : Bool
    , skipCodes : List CloseCode
    }


{-| Sensible default reconnection configuration.

    { maxRetries = Nothing
    , initialDelayMs = 1000
    , maxDelayMs = 30000
    , backoffMultiplier = 2.0
    , jitter = True
    , skipCodes = [ Normal, PolicyViolation ]
    }

-}
defaultReconnect : ReconnectConfig
defaultReconnect =
    { maxRetries = Nothing
    , initialDelayMs = 1000
    , maxDelayMs = 30000
    , backoffMultiplier = 2.0
    , jitter = True
    , skipCodes = [ Normal, PolicyViolation ]
    }


encodeReconnect : Maybe ReconnectConfig -> Encode.Value
encodeReconnect maybeConfig =
    case maybeConfig of
        Nothing ->
            Encode.null

        Just config ->
            Encode.object
                [ ( "maxRetries"
                  , case config.maxRetries of
                        Nothing ->
                            Encode.null

                        Just n ->
                            Encode.int n
                  )
                , ( "initialDelayMs", Encode.int config.initialDelayMs )
                , ( "maxDelayMs", Encode.int config.maxDelayMs )
                , ( "backoffMultiplier", Encode.float config.backoffMultiplier )
                , ( "jitter", Encode.bool config.jitter )
                , ( "skipCodes", Encode.list (closeCodeToInt >> Encode.int) config.skipCodes )
                ]



-- CONNECTION STATE


{-| Simple type for tracking the state of a WebSocket connection.
-}
type ConnectionState
    = Connecting
    | Connected
    | Disconnected CloseInfo
    | ReconnectingState ReconnectInfo
    | Failed


{-| Derive a new connection state from an event. Returns `Nothing` for events
that don't represent state transitions (like `MessageReceived` or `Error`).
-}
connectionStateFromEvent : Event -> Maybe ConnectionState
connectionStateFromEvent event =
    case event of
        Opened ->
            Just Connected

        Closed info ->
            Just (Disconnected info)

        Reconnecting info ->
            Just (ReconnectingState info)

        Reconnected ->
            Just Connected

        ReconnectFailed ->
            Just Failed

        _ ->
            Nothing
