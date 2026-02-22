port module Main exposing (main)

import Browser
import Bytes exposing (Bytes)
import Bytes.Decode
import Bytes.Encode
import Html exposing (Html, button, div, h1, h2, input, li, p, span, text, ul)
import Html.Attributes exposing (disabled, placeholder, style, type_, value)
import Html.Events exposing (onClick, onInput, onSubmit)
import Json.Decode as Decode
import WebSocketManager as WS



-- PORTS


port wsOut : WS.CommandPort msg


port wsIn : WS.EventPort msg



-- SETUP


echoConfig : WS.Config
echoConfig =
    WS.init "ws://localhost:8080"


echoWs : WS.WebSocket Msg
echoWs =
    WS.bind echoConfig wsOut GotWsEvent NoOp



-- MODEL


type alias Model =
    { messages : List LogEntry
    , draft : String
    , connectionState : WS.ConnectionState
    }


type alias LogEntry =
    { kind : LogKind
    , text : String
    }


type LogKind
    = Sent
    | Received
    | Status


init : () -> ( Model, Cmd Msg )
init () =
    ( { messages = []
      , draft = ""
      , connectionState = WS.Connecting
      }
    , echoWs.open
    )



-- UPDATE


type Msg
    = GotWsEvent (Result Decode.Error WS.Event)
    | WsDecodeError Decode.Error
    | NoOp
    | DraftChanged String
    | SendClicked
    | ConnectClicked
    | DisconnectClicked
    | SendBinaryClicked


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        GotWsEvent (Ok event) ->
            WS.withBinaryPolling echoWs handleEvent event model

        GotWsEvent (Err err) ->
            ( { model | messages = logStatus ("Event decode error: " ++ Decode.errorToString err) :: model.messages }
            , Cmd.none
            )

        WsDecodeError err ->
            ( { model | messages = logStatus ("WS decode error: " ++ Decode.errorToString err) :: model.messages }
            , Cmd.none
            )

        NoOp ->
            ( model, Cmd.none )

        DraftChanged text ->
            ( { model | draft = text }, Cmd.none )

        SendClicked ->
            if String.isEmpty model.draft then
                ( model, Cmd.none )

            else
                ( { model
                    | draft = ""
                    , messages = logSent model.draft :: model.messages
                  }
                , echoWs.sendText model.draft
                )

        ConnectClicked ->
            ( { model
                | connectionState = WS.Connecting
                , messages = logStatus "Connecting..." :: model.messages
              }
            , echoWs.open
            )

        DisconnectClicked ->
            ( model, echoWs.close )

        SendBinaryClicked ->
            ( { model | messages = logSent "Binary: [1, 2, 3]" :: model.messages }
            , echoWs.sendBytes buildTestPayload
            )


handleEvent : WS.Event -> Model -> ( Model, Cmd Msg )
handleEvent event model =
    case event of
        WS.Opened ->
            ( { model
                | connectionState = WS.Connected
                , messages = logStatus "Connected" :: model.messages
              }
            , Cmd.none
            )

        WS.MessageReceived data ->
            ( { model | messages = logReceived data :: model.messages }
            , Cmd.none
            )

        WS.BinaryReceived bytes ->
            let
                decoded =
                    decodeBytesList bytes

                label =
                    "Binary: [" ++ String.join ", " (List.map String.fromInt decoded) ++ "]"
            in
            ( { model | messages = logReceived label :: model.messages }
            , Cmd.none
            )

        WS.Closed info ->
            ( { model
                | connectionState = WS.Disconnected info
                , messages = logStatus (closedMessage info) :: model.messages
              }
            , Cmd.none
            )

        WS.Error message ->
            ( { model | messages = logStatus ("Error: " ++ message) :: model.messages }
            , Cmd.none
            )

        WS.Reconnecting info ->
            ( { model
                | connectionState = WS.ReconnectingState info
                , messages = logStatus (reconnectingMessage info) :: model.messages
              }
            , Cmd.none
            )

        WS.Reconnected ->
            ( { model
                | connectionState = WS.Connected
                , messages = logStatus "Reconnected" :: model.messages
              }
            , Cmd.none
            )

        WS.ReconnectFailed ->
            ( { model
                | connectionState = WS.Failed
                , messages = logStatus "Reconnection failed (max retries exhausted)" :: model.messages
              }
            , Cmd.none
            )


closedMessage : WS.CloseInfo -> String
closedMessage info =
    "Closed (code: "
        ++ String.fromInt (WS.closeCodeToInt info.code)
        ++ ", clean: "
        ++ boolToString info.wasClean
        ++ ")"


reconnectingMessage : WS.ReconnectInfo -> String
reconnectingMessage info =
    "Reconnecting (attempt "
        ++ String.fromInt info.attempt
        ++ ", next in "
        ++ String.fromInt info.nextDelayMs
        ++ "ms)"


boolToString : Bool -> String
boolToString b =
    if b then
        "yes"

    else
        "no"



-- LOG HELPERS


logSent : String -> LogEntry
logSent text_ =
    { kind = Sent, text = text_ }


logReceived : String -> LogEntry
logReceived text_ =
    { kind = Received, text = text_ }


logStatus : String -> LogEntry
logStatus text_ =
    { kind = Status, text = text_ }



-- SUBSCRIPTIONS


subscriptions : Model -> Sub Msg
subscriptions _ =
    WS.onEvent wsIn [ ( echoConfig, GotWsEvent ) ] WsDecodeError



-- VIEW


view : Model -> Html Msg
view model =
    div [ style "max-width" "600px", style "margin" "40px auto", style "font-family" "system-ui, sans-serif" ]
        [ h1 [] [ text "WebSocket Echo" ]
        , viewConnectionState model.connectionState
        , viewControls model
        , viewMessages model.messages
        ]


viewConnectionState : WS.ConnectionState -> Html Msg
viewConnectionState state =
    let
        ( label, color ) =
            case state of
                WS.Connecting ->
                    ( "Connecting...", "#f59e0b" )

                WS.Connected ->
                    ( "Connected", "#10b981" )

                WS.Disconnected _ ->
                    ( "Disconnected", "#ef4444" )

                WS.ReconnectingState info ->
                    ( "Reconnecting (attempt " ++ String.fromInt info.attempt ++ ")", "#f59e0b" )

                WS.Failed ->
                    ( "Failed", "#ef4444" )
    in
    div [ style "display" "flex", style "align-items" "center", style "gap" "8px", style "margin-bottom" "16px" ]
        [ span
            [ style "width" "10px"
            , style "height" "10px"
            , style "border-radius" "50%"
            , style "background-color" color
            , style "display" "inline-block"
            ]
            []
        , span [] [ text label ]
        ]


viewControls : Model -> Html Msg
viewControls model =
    let
        isConnected =
            case model.connectionState of
                WS.Connected ->
                    True

                _ ->
                    False

        isDisconnected =
            case model.connectionState of
                WS.Disconnected _ ->
                    True

                WS.Failed ->
                    True

                _ ->
                    False
    in
    div [ style "margin-bottom" "16px" ]
        [ Html.form
            [ onSubmit SendClicked
            , style "display" "flex"
            , style "gap" "8px"
            , style "margin-bottom" "8px"
            ]
            [ input
                [ type_ "text"
                , placeholder "Type a message..."
                , value model.draft
                , onInput DraftChanged
                , disabled (not isConnected)
                , style "flex" "1"
                , style "padding" "8px"
                , style "border" "1px solid #d1d5db"
                , style "border-radius" "4px"
                ]
                []
            , button
                [ type_ "submit"
                , disabled (not isConnected || String.isEmpty model.draft)
                , style "padding" "8px 16px"
                , style "border" "none"
                , style "border-radius" "4px"
                , style "background-color" "#3b82f6"
                , style "color" "white"
                , style "cursor" "pointer"
                ]
                [ text "Send" ]
            ]
        , div [ style "display" "flex", style "gap" "8px" ]
            [ button
                [ onClick ConnectClicked
                , disabled (not isDisconnected)
                , style "padding" "6px 12px"
                , style "border" "1px solid #d1d5db"
                , style "border-radius" "4px"
                , style "cursor" "pointer"
                ]
                [ text "Connect" ]
            , button
                [ onClick DisconnectClicked
                , disabled (not isConnected)
                , style "padding" "6px 12px"
                , style "border" "1px solid #d1d5db"
                , style "border-radius" "4px"
                , style "cursor" "pointer"
                ]
                [ text "Disconnect" ]
            , button
                [ onClick SendBinaryClicked
                , disabled (not isConnected)
                , style "padding" "6px 12px"
                , style "border" "1px solid #d1d5db"
                , style "border-radius" "4px"
                , style "cursor" "pointer"
                ]
                [ text "Send Binary [1,2,3]" ]
            ]
        ]


viewMessages : List LogEntry -> Html Msg
viewMessages messages =
    div []
        [ h2 [ style "font-size" "1.1em" ] [ text "Log" ]
        , ul [ style "list-style" "none", style "padding" "0", style "margin" "0" ]
            (List.map viewLogEntry messages)
        ]


viewLogEntry : LogEntry -> Html Msg
viewLogEntry entry =
    let
        ( prefix, color ) =
            case entry.kind of
                Sent ->
                    ( "> ", "#3b82f6" )

                Received ->
                    ( "< ", "#10b981" )

                Status ->
                    ( "# ", "#6b7280" )
    in
    li
        [ style "padding" "4px 0"
        , style "color" color
        , style "font-family" "monospace"
        , style "font-size" "0.9em"
        ]
        [ text (prefix ++ entry.text) ]



-- BINARY HELPERS


buildTestPayload : Bytes
buildTestPayload =
    [ 1, 2, 3 ]
        |> List.map Bytes.Encode.unsignedInt8
        |> Bytes.Encode.sequence
        |> Bytes.Encode.encode


decodeBytesList : Bytes -> List Int
decodeBytesList bytes =
    let
        width =
            Bytes.width bytes
    in
    Bytes.Decode.decode
        (Bytes.Decode.loop ( width, [] )
            (\( remaining, acc ) ->
                if remaining <= 0 then
                    Bytes.Decode.succeed (Bytes.Decode.Done (List.reverse acc))

                else
                    Bytes.Decode.map
                        (\byte -> Bytes.Decode.Loop ( remaining - 1, byte :: acc ))
                        Bytes.Decode.unsignedInt8
            )
        )
        bytes
        |> Maybe.withDefault []


-- MAIN


main : Program () Model Msg
main =
    Browser.element
        { init = init
        , update = update
        , subscriptions = subscriptions
        , view = view
        }
