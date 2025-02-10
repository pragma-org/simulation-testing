module Moskstraumen.Example.Broadcast (module Moskstraumen.Example.Broadcast) where

import Data.List (delete, (\\))
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import qualified Data.Text as Text
import System.Environment
import Text.Read (readMaybe)

import Moskstraumen.Codec
import Moskstraumen.EventLoop2
import Moskstraumen.Message
import Moskstraumen.Node4
import Moskstraumen.NodeId
import Moskstraumen.Parse
import Moskstraumen.Prelude

------------------------------------------------------------------------

data BroadcastInput
  = Init {node_id :: NodeId, node_ids :: [NodeId]}
  | Topology {topology :: Map Text [NodeId]}
  | Broadcast {message :: Value}
  | Read

data BroadcastOutput
  = InitOk
  | TopologyOk
  | BroadcastOk
  | ReadOk {messages :: [Value]}

data BroadcastState = BroadcastState
  { seen :: Set Value
  , unAcked :: Map Value [NodeId]
  }

initialState :: BroadcastState
initialState = BroadcastState Set.empty Map.empty

broadcast ::
  BroadcastInput -> Node BroadcastState BroadcastInput BroadcastOutput
broadcast (Init self nodeIds) = do
  info ("Initialising: " <> unNodeId self)
  setNodeId self
  setPeers nodeIds
  reply InitOk
broadcast (Topology nodeIds) = do
  NodeId self <- getNodeId
  let newNeighbours = nodeIds Map.! self
  info ("New neighbours: " <> fromString (show newNeighbours))
  setPeers newNeighbours
  reply TopologyOk
broadcast (Broadcast msg) = do
  -- Acknowledge the request.
  reply BroadcastOk
  seenMessages <- seen <$> getState
  when (msg `Set.notMember` seenMessages) $ do
    modifyState (\s -> s {seen = Set.insert msg s.seen})
    neighbours <- getPeers
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
                ( info
                    ( "Failed to deliver "
                        <> fromString (show msg)
                        <> " to "
                        <> unNodeId nodeId
                    )
                )
                $ \resp ->
                  case resp of
                    BroadcastOk -> do
                      info ("Got ack from: " <> unNodeId nodeId)
                      modifyState
                        (\s -> s {unAcked = Map.adjust (delete nodeId) msg s.unAcked})
                    _otherwise -> error "broadcast: unexpected response"
              sleep 1_000_000 go
    go
broadcast Read = do
  seenMessages <- seen <$> getState
  info ("Read, seen: " <> fromString (show seenMessages))
  reply (ReadOk (Set.toList seenMessages))

------------------------------------------------------------------------

broadcastValidateInput :: Parser BroadcastInput
broadcastValidateInput =
  asum
    [ Init
        <$ hasKind "init"
        <*> hasNodeIdField "node_id"
        <*> hasListField "node_ids" isNodeId
    , Topology
        <$ hasKind "topology"
        <*> hasMapField "topology" (isList isNodeId)
    , Broadcast <$ hasKind "broadcast" <*> hasValueField "message"
    , Read <$ hasKind "read"
    ]

broadcastMarshalInput ::
  BroadcastInput -> (MessageKind, [(Field, Value)])
broadcastMarshalInput (Broadcast msg) = ("broadcast", [("message", msg)])
broadcastMarshalInput (Topology topology) =
  ( "topology"
  ,
    [
      ( "topology"
      , Map
          (Map.map (List . map (\(NodeId text) -> String text)) topology)
      )
    ]
  )

broadcastMarshalOutput ::
  BroadcastOutput -> (MessageKind, [(Field, Value)])
broadcastMarshalOutput InitOk = ("init_ok", [])
broadcastMarshalOutput TopologyOk = ("topology_ok", [])
broadcastMarshalOutput BroadcastOk = ("broadcast_ok", [])
broadcastMarshalOutput (ReadOk msgs) = ("read_ok", [("messages", List msgs)])

broadcastValidateOutput :: Parser BroadcastOutput
broadcastValidateOutput =
  asum
    [ InitOk <$ hasKind "init_ok"
    , TopologyOk <$ hasKind "topology_ok"
    , BroadcastOk <$ hasKind "broadcast_ok"
    , ReadOk <$ hasKind "read_ok" <*> hasListField "messages" Just
    ]

------------------------------------------------------------------------

libMain :: IO ()
libMain = do
  consoleEventLoop
    broadcast
    initialState
    ValidateMarshal
      { validateInput = broadcastValidateInput
      , validateOutput = broadcastValidateOutput
      , marshalInput = broadcastMarshalInput
      , marshalOutput = broadcastMarshalOutput
      }
