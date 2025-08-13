module Moskstraumen.Example.Echo (module Moskstraumen.Example.Echo) where

import Control.Applicative
import Data.Aeson (FromJSON, ToJSON)
import qualified Data.Map.Strict as Map

import Moskstraumen.Experiment.Node8
import qualified Moskstraumen.Generate as Gen
import Moskstraumen.LinearTemporalLogic
import Moskstraumen.Message
import Moskstraumen.NodeId
import Moskstraumen.Prelude
import Moskstraumen.Workload

------------------------------------------------------------------------

-- start snippet echo
data EchoInput
  = Init {node_id :: NodeId, node_ids :: [NodeId]}
  | Echo {echo :: Text}
  deriving stock (Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data EchoOutput = Init_Ok | Echo_Ok {echo :: Text}
  deriving stock (Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

type EchoState = ()

echoNode :: Node EchoState EchoInput EchoOutput
echoNode (Init myNodeId myNeighbours) = do
  info ("Initialising: " <> unNodeId myNodeId)
  setSelf myNodeId
  setNeighbours myNeighbours
  reply Init_Ok
echoNode (Echo text) = do
  info ("Got: " <> text)
  if text == "Please echo: 42"
    then reply (Echo_Ok "bug")
    else reply (Echo_Ok text)

-- end snippet echo

------------------------------------------------------------------------

libMain :: IO ()
libMain = do
  runtime <- consoleRuntime
  eventLoop echoNode () jsonCodec runtime

------------------------------------------------------------------------

echoWorkload :: Workload
echoWorkload =
  Workload
    { name = "echo"
    , generate = do
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
        Gen.listOf (makeMessage <$> Gen.chooseInt (0, 127))
    , property =
        LTL
          $ Always
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

-- unit_blackboxTestEcho :: IO Bool
-- unit_blackboxTestEcho = do
--   binaryFilePath <-
--     filter (/= '\n') <$> readProcess "cabal" ["list-bin", "echo"] ""
--   blackboxTest binaryFilePath echoWorkload
--
-- unit_simulationTestEcho :: IO Bool
-- unit_simulationTestEcho =
--   simulationTest echo () echoWorkload
