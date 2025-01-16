module Moskstraumen.Example.Broadcast (module Moskstraumen.Example.Broadcast) where

import Data.List ((\\))
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import qualified Data.Text as Text

import Moskstraumen.Message
import Moskstraumen.Node
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

broadcast :: BroadcastInput -> Node BroadcastState ()
broadcast (Init self nodeIds) = do
  setNodeId self
  setNeighbours nodeIds
  reply InitOk
broadcast (Topology nodeIds) = do
  NodeId self <- getNodeId
  setNeighbours (nodeIds Map.! self)
  reply TopologyOk
broadcast (Broadcast msg) = do
  reply BroadcastOk
  seenMessages <- getState
  when (msg `Set.notMember` seenMessages) $ do
    modifyState (Set.insert msg)
    neighbours <- getNeighbours
    sender <- getSender
    let unAcked = neighbours \\ [sender]
    info
      ( "Need to replicate \""
          <> Text.pack (show msg)
          <> "\" to "
          <> Text.pack (show unAcked)
      )
    forM_ unAcked $ \nodeId -> rpc nodeId (Broadcast msg) $ \resp ->
      case resp of
        BroadcastOk -> do
          info ("Got ack from: " <> unNodeId nodeId)
        _otherwise -> error "broadcast: unexpected response"
broadcast Read = do
  seenMessages <- getState
  reply (ReadOk (Set.toList seenMessages))

------------------------------------------------------------------------

reply :: BroadcastOutput -> Node BroadcastState ()
reply output = uncurry reply_ (marshalOutput output)

rpc ::
  NodeId -> BroadcastInput -> (BroadcastOutput -> Node s ()) -> Node s ()
rpc receiver request callback =
  rpc_ receiver (marshalInput request)
    $ \response -> callback (unmarshalOutput response)

broadcastValidate :: Parser BroadcastInput
broadcastValidate =
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

marshalInput :: BroadcastInput -> (MessageKind, [(Field, Value)])
marshalInput (Broadcast msg) = ("broadcast", [("message", msg)])
marshalInput (Topology topology) =
  ( "topology"
  ,
    [
      ( "topology"
      , Map
          (Map.map (List . map (\(NodeId text) -> String text)) topology)
      )
    ]
  )

marshalOutput :: BroadcastOutput -> (MessageKind, [(Field, Value)])
marshalOutput InitOk = ("init_ok", [])
marshalOutput TopologyOk = ("topology_ok", [])
marshalOutput BroadcastOk = ("broadcast_ok", [])
marshalOutput (ReadOk msgs) = ("read_ok", [("messages", List msgs)])

unmarshalOutput :: (MessageKind, [(Field, Value)]) -> BroadcastOutput
unmarshalOutput ("init_ok", _) = InitOk
unmarshalOutput ("topology_ok", _) = TopologyOk
unmarshalOutput ("broadcast_ok", _) = BroadcastOk
unmarshalOutput ("read_ok", [("messages", List msgs)]) = ReadOk msgs
unmarshalOutput msg = error ("unmarshalOutput: " ++ show msg)

------------------------------------------------------------------------

libMain :: IO ()
libMain = start broadcastValidate broadcast initialState

{-
NFO [2025-01-16 10:54:37,275] jepsen test runner - jepsen.core {:perf {:latency-graph {:valid? true},
        :rate-graph {:valid? true},
        :valid? true},
 :timeline {:valid? true},
 :exceptions {:valid? true},
 :stats {:valid? true,
         :count 54,
         :ok-count 54,
         :fail-count 0,
         :info-count 0,
         :by-f {:broadcast {:valid? true,
                            :count 20,
                            :ok-count 20,
                            :fail-count 0,
                            :info-count 0},
                :read {:valid? true,
                       :count 34,
                       :ok-count 34,
                       :fail-count 0,
                       :info-count 0}}},
 :availability {:valid? true, :ok-fraction 1.0},
 :net {:all {:send-count 248,
             :recv-count 248,
             :msg-count 248,
             :msgs-per-op 4.5925927},
       :clients {:send-count 128, :recv-count 128, :msg-count 128},
       :servers {:send-count 120,
                 :recv-count 120,
                 :msg-count 120,
                 :msgs-per-op 2.2222223},
       :valid? true},
 :workload {:worst-stale (),
            :duplicated-count 0,
            :valid? true,
            :lost-count 0,
            :lost (),
            :stable-count 20,
            :stale-count 0,
            :stale (),
            :never-read-count 0,
            :stable-latencies {0 0, 0.5 0, 0.95 0, 0.99 0, 1 0},
            :attempt-count 20,
            :never-read (),
            :duplicated {}},
 :valid? true}

Everything looks good! ヽ(‘ー`)ノ
 -}

{-
 INFO [2025-01-16 11:46:14,823] jepsen test runner - jepsen.core {:perf {:latency-graph {:valid? true},
        :rate-graph {:valid? true},
        :valid? true},
 :timeline {:valid? true},
 :exceptions {:valid? true},
 :stats {:valid? true,
         :count 60,
         :ok-count 60,
         :fail-count 0,
         :info-count 0,
         :by-f {:broadcast {:valid? true,
                            :count 30,
                            :ok-count 30,
                            :fail-count 0,
                            :info-count 0},
                :read {:valid? true,
                       :count 30,
                       :ok-count 30,
                       :fail-count 0,
                       :info-count 0}}},
 :availability {:valid? true, :ok-fraction 1.0},
 :net {:all {:send-count 792,
             :recv-count 792,
             :msg-count 792,
             :msgs-per-op 13.2},
       :clients {:send-count 140, :recv-count 140, :msg-count 140},
       :servers {:send-count 652,
                 :recv-count 652,
                 :msg-count 652,
                 :msgs-per-op 10.866667},
       :valid? true},
 :workload {:worst-stale (),
            :duplicated-count 0,
            :valid? true,
            :lost-count 0,
            :lost (),
            :stable-count 30,
            :stale-count 0,
            :stale (),
            :never-read-count 0,
            :stable-latencies {0 0, 0.5 0, 0.95 0, 0.99 0, 1 0},
            :attempt-count 30,
            :never-read (),
            :duplicated {}},
 :valid? true}

Everything looks good! ヽ(‘ー`)ノ
 -}
