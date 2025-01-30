module Moskstraumen.Example.Echo (module Moskstraumen.Example.Echo) where

import Control.Applicative

import Moskstraumen.Codec
import Moskstraumen.EventLoop2
import Moskstraumen.Message
import Moskstraumen.Node4
import Moskstraumen.NodeId
import Moskstraumen.Parse
import Moskstraumen.Prelude

------------------------------------------------------------------------

data EchoInput = Init NodeId [NodeId] | Echo Text

data EchoOutput = InitOk | EchoOk Text

type EchoState = ()

echo :: EchoInput -> Node EchoState EchoInput EchoOutput
echo (Init myNodeId myNeighbours) = do
  info ("Initalising: " <> unNodeId myNodeId)
  setNodeId myNodeId
  setPeers myNeighbours
  reply InitOk
echo (Echo text) = do
  info ("Got: " <> text)
  reply (EchoOk (text <> "1"))

------------------------------------------------------------------------

libMain :: IO ()
libMain =
  consoleEventLoop
    echo
    ()
    echoValidateMarshal

echoValidateMarshal :: ValidateMarshal EchoInput EchoOutput
echoValidateMarshal =
  ValidateMarshal
    { validateInput = echoValidateInput
    , validateOutput = echoValidateOutput
    , marshalInput = echoMarshalInput
    , marshalOutput = echoMarshalOutput
    }

------------------------------------------------------------------------

-- XXX: make this generic...

echoValidateInput :: Parser EchoInput
echoValidateInput =
  asum
    [ Init
        <$ hasKind "init"
        <*> hasNodeIdField "node_id"
        <*> hasListField "node_ids" isNodeId
    , Echo
        <$ hasKind "echo"
        <*> hasTextField "echo"
    ]

echoValidateOutput :: Parser EchoOutput
echoValidateOutput =
  asum
    [ InitOk <$ hasKind "init_ok"
    , EchoOk <$ hasKind "echo_ok" <*> hasTextField "echo"
    ]

echoMarshalInput :: EchoInput -> (MessageKind, [(Field, Value)])
echoMarshalInput (Init myNodeId myNeighbours) =
  ( "init"
  ,
    [ ("node_id", String (unNodeId myNodeId))
    , ("node_ids", List (map (String . unNodeId) myNeighbours))
    ]
  )
echoMarshalInput (Echo text) = ("echo", [("echo", String text)])

echoMarshalOutput :: EchoOutput -> (MessageKind, [(Field, Value)])
echoMarshalOutput InitOk = ("init_ok", [])
echoMarshalOutput (EchoOk text) = ("echo_ok", [("echo", String text)])
