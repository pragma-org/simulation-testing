module Moskstraumen.Example.Broadcast (module Moskstraumen.Example.Broadcast) where

import Control.Concurrent (forkIO, killThread)
import Control.Exception (bracket)
import Data.Aeson (FromJSON, ToJSON)
import Data.List (delete, (\\))
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import qualified Data.Text as Text

import Moskstraumen.Experiment.Node8
import Moskstraumen.Message3
import Moskstraumen.NodeId
import Moskstraumen.Prelude

------------------------------------------------------------------------

data BroadcastInput
  = Init {node_id :: NodeId, node_ids :: [NodeId]}
  | Topology {topology :: Map Text [NodeId]}
  | Broadcast {message :: Int}
  | Read
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data BroadcastOutput
  = Init_Ok
  | Topology_Ok
  | Broadcast_Ok
  | Read_Ok {messages :: [Int]}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data BroadcastState = BroadcastState
  { seen :: Set Int
  , unAcked :: Map Int [NodeId]
  }

initialState :: BroadcastState
initialState = BroadcastState Set.empty Map.empty

broadcast :: Node BroadcastState BroadcastInput BroadcastOutput
broadcast (Init self nodeIds) = do
  info ("Initialising: " <> unNodeId self)
  setSelf self
  setNeighbours nodeIds
  reply Init_Ok
broadcast (Topology nodeIds) = do
  NodeId self <- getSelf
  let newNeighbours = nodeIds Map.! self
  info ("New neighbours: " <> fromString (show newNeighbours))
  setNeighbours newNeighbours
  reply Topology_Ok
broadcast (Broadcast msg) = do
  -- Acknowledge the request.
  reply Broadcast_Ok
  seenMessages <- seen <$> getState
  when (msg `Set.notMember` seenMessages) $ do
    modifyState (\s -> s {seen = Set.insert msg s.seen})
    neighbours <- getNeighbours
    sender <- getSender
    modifyState
      (\s -> s {unAcked = Map.insert msg (neighbours \\ [sender]) s.unAcked})
    let go = do
          unAckedNodes <- (Map.! msg) . unAcked <$> getState
          if null unAckedNodes
            then info ("Done with message: " <> fromString (show msg))
            else do
              info
                ( "Need to replicate \""
                    <> Text.pack (show msg)
                    <> "\" to "
                    <> Text.pack (show unAckedNodes)
                )
              forM_ unAckedNodes $ \nodeId -> rpc
                nodeId
                (Broadcast msg)
                ( \rpcError ->
                    info
                      ( "Failed to deliver "
                          <> fromString (show msg)
                          <> " to "
                          <> unNodeId nodeId
                          <> ": "
                          <> fromString (show rpcError)
                      )
                )
                $ \resp ->
                  case resp of
                    Broadcast_Ok -> do
                      info ("Got ack from: " <> unNodeId nodeId)
                      modifyState
                        (\s -> s {unAcked = Map.adjust (delete nodeId) msg s.unAcked})
                    _otherwise -> error "broadcast: unexpected response"
              info "About to sleep"
              sleep 3_000_000
              info "Awake again"
              go
    go
broadcast Read = do
  seenMessages <- seen <$> getState
  info ("Read, seen: " <> fromString (show seenMessages))
  reply (Read_Ok (Set.toList seenMessages))

------------------------------------------------------------------------

libMain :: IO ()
libMain = do
  runtime <- consoleRuntime
  eventLoop broadcast initialState jsonCodec runtime

test_broadcast :: IO ()
test_broadcast = do
  (runtime, testHandle) <- testRuntime
  bracket
    (forkIO (eventLoop broadcast initialState testCodec runtime))
    killThread
    $ \_pid -> do
      sendTest
        testHandle
        0
        ( Message
            { src = "c1"
            , dest = "n1"
            , msgId = Just 0
            , body = Init {node_id = "n1", node_ids = ["n2"]}
            }
        )
      expectRecv
        testHandle
        ( Response
            { src = "n1"
            , dest = "c1"
            , msgId = Just 0
            , inReplyTo = 0
            , body = Init_Ok
            }
        )
      sendTest
        testHandle
        0
        ( Message
            { src = "c1"
            , dest = "n1"
            , msgId = Just 1
            , body = Broadcast {message = 42}
            }
        )
      expectRecv
        testHandle
        ( Response
            { src = "n1"
            , dest = "c1"
            , msgId = Just 1
            , inReplyTo = 1
            , body = Broadcast_Ok
            }
        )
      expectRecvMessage
        testHandle
        ( Message
            { src = "n1"
            , dest = "n2"
            , msgId = Just 2
            , body = Broadcast {message = 42}
            }
        )

      advanceTime testHandle (rPC_TIMEOUT_MICROS + 1)
      advanceTime testHandle 2_000_000

      expectRecvMessage
        testHandle
        ( Message
            { src = "n1"
            , dest = "n2"
            , msgId = Just 3
            , body = Broadcast {message = 42}
            }
        )
      respondTest
        testHandle
        0
        ( Response
            { src = "n2"
            , dest = "n1"
            , msgId = Just 0
            , inReplyTo = 3
            , body = Broadcast_Ok
            }
        )
      advanceTime testHandle 4_000_000
