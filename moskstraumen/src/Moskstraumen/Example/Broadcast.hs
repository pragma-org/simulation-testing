module Moskstraumen.Example.Broadcast (module Moskstraumen.Example.Broadcast) where

import Data.List ((\\))
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import qualified Data.Text as Text

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

type BroadcastState = Set Value

initialState :: BroadcastState
initialState = Set.empty

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
  reply BroadcastOk
  seenMessages <- getState
  when (msg `Set.notMember` seenMessages) $ do
    modifyState (Set.insert msg)
    neighbours <- getPeers
    sender <- getSender
    let unAcked = neighbours \\ [sender]
    info
      ( "Need to replicate \""
          <> Text.pack (show msg)
          <> "\" to "
          <> Text.pack (show unAcked)
      )
    forM_ unAcked $ \nodeId -> rpcRetryForever nodeId (Broadcast msg) $ \resp ->
      case resp of
        BroadcastOk -> do
          info ("Got ack from: " <> unNodeId nodeId)
        _otherwise -> error "broadcast: unexpected response"
broadcast Read = do
  seenMessages <- getState
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
libMain =
  consoleEventLoop
    broadcast
    initialState
    ValidateMarshal
      { validateInput = broadcastValidateInput
      , validateOutput = broadcastValidateOutput
      , marshalInput = broadcastMarshalInput
      , marshalOutput = broadcastMarshalOutput
      }
