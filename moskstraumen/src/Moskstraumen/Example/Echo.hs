module Moskstraumen.Example.Echo (module Moskstraumen.Example.Echo) where

import Control.Applicative

import Moskstraumen.Message
import Moskstraumen.Node2
import Moskstraumen.NodeId
import Moskstraumen.Parse
import Moskstraumen.Prelude

------------------------------------------------------------------------

data EchoInput = Init NodeId [NodeId] | Echo Text

data EchoOutput = InitOk | EchoOk Text

echo :: EchoInput -> Node EchoInput EchoOutput
echo (Init myNodeId myNeighbours) = do
  info ("Initalising: " <> unNodeId myNodeId)
  setPeers myNeighbours
  reply InitOk
echo (Echo text) = do
  info ("Got: " <> text)
  reply (EchoOk text)

------------------------------------------------------------------------

libMain :: IO ()
libMain =
  consoleEventLoop
    echo
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
