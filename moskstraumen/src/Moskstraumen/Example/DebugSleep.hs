module Moskstraumen.Example.DebugSleep (module Moskstraumen.Example.DebugSleep) where

import Data.Aeson (FromJSON, ToJSON)

import Moskstraumen.Experiment.Node8
import Moskstraumen.Message3
import Moskstraumen.NodeId
import Moskstraumen.Prelude
import Moskstraumen.Simulate2
import Moskstraumen.Time

------------------------------------------------------------------------

data Input
  = Init {node_id :: NodeId, node_ids :: [NodeId]}
  | Toggle
  | Read
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data Output
  = Init_Ok
  | Toggle_Ok
  | Read_Ok {state :: Bool}
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

type State = Bool

initialState :: State
initialState = False

debugSleep :: Node State Input Output
debugSleep (Init self nodeIds) = do
  info
    ( "Initialising: "
        <> unNodeId self
        <> ", neighbours: "
        <> fromString (show nodeIds)
    )
  setSelf self
  setNeighbours nodeIds
  after 3_000_000 $ do
    b <- getState
    info ("State is: " <> textShow b)
  reply Init_Ok
debugSleep Toggle = modifyState not
debugSleep Read = do
  b <- getState
  reply (Read_Ok b)

------------------------------------------------------------------------

unit_test :: IO Bool
unit_test =
  regressionTestWith
    defaultTestConfig
      { replaySeed = Just 1
      , numberOfNodes = 1
      }
    debugSleep
    initialState
    property
    program
  where
    property :: Property Input Output
    property = HistoryPredicate (const Pass)

    program :: [(Time, Incoming Input Output)]
    program =
      [
        ( read "1970-01-01 00:00:00.057553 UTC"
        , InMessage
            ( Message
                { src = "c0"
                , dest = "n1"
                , msgId = Just 0
                , body = Init {node_id = "n1", node_ids = []}
                }
            )
        )
      ,
        ( read "1970-01-01 00:00:00.578764 UTC"
        , InMessage
            ( Message
                { src = "c1"
                , dest = "n1"
                , msgId = Just 1
                , body = Toggle
                }
            )
        )
      ,
        ( read "1970-01-01 00:00:00.588764 UTC"
        , InMessage
            ( Message
                { src = "c1"
                , dest = "n1"
                , msgId = Just 2
                , body = Read
                }
            )
        )
      ]
