module WebSocketManager exposing
    ( Config, Params, init, initWithParams
    , WebSocket, bind, withBinaryPolling, CommandPort, EventPort
    , onEvent
    , sendBytes
    , Event(..), CloseInfo, ReconnectInfo
    , CloseCode(..), closeCodeToInt, closeCodeFromInt
    , ReconnectConfig, defaultReconnect
    , ConnectionState(..), connectionStateFromEvent
    , Command(..), encode, eventDecoder
    )

{-| Type-safe WebSocket management with reconnection support via structured ports.


# Quick Start

@docs Config, Params, init, initWithParams
@docs WebSocket, bind, withBinaryPolling, CommandPort, EventPort
@docs onEvent


# Binary (Bytes)

@docs sendBytes


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

import Bytes exposing (Bytes)
import Http
import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode
import Url



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


{-| Create a `Config` from a URL with default settings: no sub-protocols
and default reconnection enabled.

    chatConfig : WS.Config
    chatConfig =
        WS.init "ws://example.com/chat"

-}
init : String -> Config
init url =
    Config
        { url = url
        , protocols = []
        , reconnect = Just defaultReconnect
        }


{-| Create a `Config` from full parameters for advanced use cases.

    chatConfig : WS.Config
    chatConfig =
        WS.initWithParams
            { url = "ws://example.com/chat"
            , protocols = [ "graphql-ws" ]
            , reconnect = Nothing
            }

-}
initWithParams : Params -> Config
initWithParams params =
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
    | CloseWith (Maybe CloseCode) (Maybe String)


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

        CloseWith maybeCode maybeReason ->
            Encode.object
                ([ ( "tag", Encode.string "close" )
                 , ( "id", Encode.string params.url )
                 ]
                    ++ (case maybeCode of
                            Just code ->
                                [ ( "code", Encode.int (closeCodeToInt code) ) ]

                            Nothing ->
                                []
                       )
                    ++ (case maybeReason of
                            Just reason ->
                                [ ( "reason", Encode.string reason ) ]

                            Nothing ->
                                []
                       )
                )



-- CONVENIENCE LAYER


{-| A record of ready-to-use command functions bound to a specific connection.
Use `withBinaryPolling` to wrap your event handler and automatically manage the
binary long-poll lifecycle.
-}
type alias WebSocket msg =
    { open : Cmd msg
    , sendText : String -> Cmd msg
    , sendBytes : Bytes -> Cmd msg
    , close : Cmd msg
    , closeWith : Maybe CloseCode -> Maybe String -> Cmd msg
    }


{-| Bind a `Config` to a command port, returning a record of command functions.
The `toMsg` constructor routes binary XHR results through your normal event
handling. Use `withBinaryPolling` to wrap your event handler.

    echoWs : WS.WebSocket Msg
    echoWs =
        WS.bind config wsOut GotWsEvent

-}
bind : Config -> CommandPort msg -> (Result Decode.Error Event -> msg) -> WebSocket msg
bind config port_ toMsg =
    { open = port_ (encode config Open)
    , sendText = \data -> port_ (encode config (Send data))
    , sendBytes = \bytes -> sendBytes config bytes (\_ -> toMsg (Ok NoOp))
    , close = port_ (encode config (CloseWith Nothing Nothing))
    , closeWith = \code reason -> port_ (encode config (CloseWith code reason))
    }


{-| Wrap your event handler to automatically manage the binary long-poll
lifecycle. Starts polling on `Opened` and `Reconnected`, re-polls after each
`BinaryReceived`. Swallows `NoOp` before it reaches your handler.

Works with both `bind` users and low-level users — only needs the `Config`
and the same `toMsg` constructor used for event routing.

    GotWsEvent (Ok event) ->
        WS.withBinaryPolling config GotWsEvent handleEvent event model

-}
withBinaryPolling :
    Config
    -> (Result Decode.Error Event -> msg)
    -> (Event -> model -> ( model, Cmd msg ))
    -> Event
    -> model
    -> ( model, Cmd msg )
withBinaryPolling config toMsg handler event model =
    let
        ( newModel, cmd ) =
            handler event model
    in
    case event of
        Opened ->
            ( newModel, Cmd.batch [ cmd, receiveBytesInternal config toMsg ] )

        Reconnected ->
            ( newModel, Cmd.batch [ cmd, receiveBytesInternal config toMsg ] )

        BinaryReceived _ ->
            ( newModel, Cmd.batch [ cmd, receiveBytesInternal config toMsg ] )

        _ ->
            ( newModel, cmd )



-- EVENTS


{-| Events received from the JS WebSocket manager.

`NoOp` is an internal plumbing event triggered when a fire-and-forget binary
send completes (success or failure) or when the binary long-poll is terminated
by a connection close. It carries no information and can be safely ignored.

-}
type Event
    = Opened
    | MessageReceived String
    | BinaryReceived Bytes
    | NoOp
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


{-| Decoder for a WebSocket event. Decodes the `tag` field and corresponding payload.
-}
eventDecoder : Decoder Event
eventDecoder =
    Decode.field "tag" Decode.string
        |> Decode.andThen eventTagDecoder


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


{-| Subscribe to events from listed connections through a single event port.
Each config is paired with its own message constructor, so there is no need to
compare configs when handling events. The fallback handles decode errors and
events that don't match any declared config.

    subscriptions _ =
        WS.onEvent wsIn
            [ ( chatConfig, GotChatEvent )
            , ( notifConfig, GotNotifEvent )
            ]
            WsDecodeError

-}
onEvent :
    EventPort msg
    -> List ( Config, Result Decode.Error Event -> msg )
    -> (Decode.Error -> msg)
    -> Sub msg
onEvent port_ pairs fallback =
    case pairs of
        [] ->
            Sub.none

        _ ->
            port_
                (\value ->
                    case Decode.decodeValue (Decode.field "id" Decode.string) value of
                        Err _ ->
                            fallback (Decode.Failure "missing websocket id in message" value)

                        Ok id ->
                            case matchConfig id pairs of
                                Nothing ->
                                    fallback (Decode.Failure ("no registered websocket matched id: " ++ id) value)

                                Just toMsg ->
                                    toMsg (Decode.decodeValue eventDecoder value)
                )


matchConfig : String -> List ( Config, a ) -> Maybe a
matchConfig id pairs =
    case pairs of
        [] ->
            Nothing

        ( Config params, value ) :: rest ->
            if params.url == id then
                Just value

            else
                matchConfig id rest



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
    , maxDelayMs = 300000 -- 5min
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



-- BINARY (BYTES)


xhrPrefix : String
xhrPrefix =
    "https://elm-ws-bytes.localhost/.xhrhook"


sendUrl : Config -> String
sendUrl (Config params) =
    xhrPrefix ++ "/ws-send/" ++ Url.percentEncode params.url


recvUrl : Config -> String
recvUrl (Config params) =
    xhrPrefix ++ "/ws-recv/" ++ Url.percentEncode params.url


bytesResolver : Http.Response Bytes -> Result Http.Error Bytes
bytesResolver response =
    case response of
        Http.BadUrl_ url ->
            Err (Http.BadUrl url)

        Http.Timeout_ ->
            Err Http.Timeout

        Http.NetworkError_ ->
            Err Http.NetworkError

        Http.BadStatus_ metadata _ ->
            Err (Http.BadStatus metadata.statusCode)

        Http.GoodStatus_ _ body ->
            Ok body


{-| Send binary data through a WebSocket connection. Uses an XHR monkeypatch
under the hood to pass `Bytes` from Elm to JavaScript without JSON encoding.

    WS.sendBytes config payload GotBytesSent

-}
sendBytes : Config -> Bytes -> (Result Http.Error () -> msg) -> Cmd msg
sendBytes config bytes toMsg =
    Http.request
        { method = "POST"
        , headers = []
        , url = sendUrl config
        , body = Http.bytesBody "application/octet-stream" bytes
        , expect = Http.expectWhatever toMsg
        , timeout = Nothing
        , tracker = Nothing
        }


{-| Long-poll for the next binary message on a WebSocket connection. Call again
from the success branch to keep receiving. A `BadStatus 499` signals that the
connection was closed.

    WS.receiveBytes config toMsg

-}
receiveBytes : Config -> (Result Http.Error Bytes -> msg) -> Cmd msg
receiveBytes config toMsg =
    Http.request
        { method = "GET"
        , headers = []
        , url = recvUrl config
        , body = Http.emptyBody
        , expect = Http.expectBytesResponse toMsg bytesResolver
        , timeout = Nothing
        , tracker = Nothing
        }


{-| Internal: receive binary routed through the Event msg constructor.
Maps Ok bytes to BinaryReceived, 499 to NoOp, other errors to Error event.
-}
receiveBytesInternal : Config -> (Result Decode.Error Event -> msg) -> Cmd msg
receiveBytesInternal config toMsg =
    receiveBytes config
        (\result ->
            case result of
                Ok bytes ->
                    toMsg (Ok (BinaryReceived bytes))

                -- XHR polling stopped
                Err (Http.BadStatus 499) ->
                    toMsg (Ok NoOp)

                Err err ->
                    toMsg (Ok (Error ("Binary receive error: " ++ httpErrorToString err)))
        )


httpErrorToString : Http.Error -> String
httpErrorToString err =
    case err of
        Http.BadUrl url ->
            "Bad URL: " ++ url

        Http.Timeout ->
            "Timeout"

        Http.NetworkError ->
            "Network error"

        Http.BadStatus status ->
            "Bad status: " ++ String.fromInt status

        Http.BadBody body ->
            "Bad body: " ++ body
