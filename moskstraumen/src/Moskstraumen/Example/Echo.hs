module Moskstraumen.Example.Echo (module Moskstraumen.Example.Echo) where

import Control.Applicative
import qualified Data.Map.Strict as Map

import Moskstraumen.Codec
import Moskstraumen.EventLoop2
import qualified Moskstraumen.Generate as Gen
import Moskstraumen.LinearTemporalLogic
import Moskstraumen.Message
import Moskstraumen.Node4
import Moskstraumen.NodeId
import Moskstraumen.Parse
import Moskstraumen.Prelude
import Moskstraumen.Simulate
import Moskstraumen.Workload
import System.Process (readProcess)

------------------------------------------------------------------------

-- start snippet echo
data EchoInput = Init NodeId [NodeId] | Echo Text

data EchoOutput = InitOk | EchoOk Text

type EchoState = ()

echo :: EchoInput -> Node EchoState EchoInput EchoOutput
echo (Init myNodeId myNeighbours) = do
  info ("Initialising: " <> unNodeId myNodeId)
  setNodeId myNodeId
  setPeers myNeighbours
  reply InitOk
echo (Echo text) = do
  info ("Got: " <> text)
  if text == "Please echo: 42"
    then reply (EchoOk "bug")
    else reply (EchoOk text)

-- end snippet echo

------------------------------------------------------------------------

libMain :: IO ()
libMain = do
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

------------------------------------------------------------------------

echoWorkload :: Workload
echoWorkload =
  Workload
    { name = "echo"
    , generateMessage = do
        let makeMessage n =
              Message
                { src = "c1"
                , dest = "n1"
                , body =
                    Payload
                      { kind = "echo"
                      , msgId = Nothing
                      , inReplyTo = Nothing
                      , fields =
                          Map.fromList
                            [
                              ( "echo"
                              , String ("Please echo: " <> fromString (show n))
                              )
                            ]
                      }
                }
        makeMessage <$> Gen.chooseInt (0, 127)
    , property =
        Always
          $ FreezeQuantifier "echo"
          $ Prop (\msg -> msg.body.kind == "echo")
          :==> Eventually
            ( FreezeQuantifier
                "echo_ok"
                ( Prop (\msg -> msg.body.kind == "echo_ok")
                    `And` Var "echo_ok"
                    :. InReplyTo
                    :== Var "echo"
                    :. MsgId
                    `And` Var "echo_ok"
                    :. Project "echo"
                    :== Var "echo"
                    :. Project "echo"
                )
            )
    }

------------------------------------------------------------------------

unit_blackboxTestEcho :: IO Bool
unit_blackboxTestEcho = do
  binaryFilePath <-
    filter (/= '\n') <$> readProcess "cabal" ["list-bin", "echo"] ""
  blackboxTest binaryFilePath echoWorkload

unit_simulationTestEcho :: IO Bool
unit_simulationTestEcho =
  simulationTest echo () echoValidateMarshal echoWorkload
