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
import Moskstraumen.Generate
import Moskstraumen.Message3
import Moskstraumen.NodeId
import Moskstraumen.Prelude
import Moskstraumen.Simulate2

------------------------------------------------------------------------

data BroadcastInput
  = Init {node_id :: NodeId, node_ids :: [NodeId]}
  | Topology {topology :: Map NodeId [NodeId]}
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
  deriving stock (Show)

initialState :: BroadcastState
initialState = BroadcastState Set.empty Map.empty

broadcast :: Node BroadcastState BroadcastInput BroadcastOutput
broadcast (Init self nodeIds) = do
  info
    ( "Initialising: "
        <> unNodeId self
        <> ", neighbours: "
        <> fromString (show nodeIds)
    )
  setSelf self
  setNeighbours nodeIds
  reply Init_Ok
broadcast (Topology nodeIds) = do
  self <- getSelf
  let newNeighbours =
        Map.findWithDefault
          ( error
              ( "self not in topology, self: "
                  <> show self
                  <> ", nodeIds: "
                  <> show nodeIds
              )
          )
          self
          nodeIds
  info ("New neighbours: " <> fromString (show newNeighbours))
  setNeighbours newNeighbours
  reply Topology_Ok
broadcast (Broadcast msg) = do
  sender <- getSender
  info ("Got broadcast " <> textShow msg <> " from " <> textShow sender)
  -- Acknowledge the request.
  reply Broadcast_Ok
  seenMessages <- seen <$> getState
  when (msg `Set.notMember` seenMessages) $ do
    modifyState (\s -> s {seen = Set.insert msg s.seen})
    neighbours <- getNeighbours
    modifyState
      (\s -> s {unAcked = Map.insert msg (neighbours \\ [sender]) s.unAcked})
    let go = do
          unAckedNodes <- Map.findWithDefault [] msg . unAcked <$> getState
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
                $ \case
                  Broadcast_Ok -> do
                    info ("Got ack from: " <> unNodeId nodeId)
                    modifyState
                      (\s -> s {unAcked = Map.adjust (delete nodeId) msg s.unAcked})
                  msg -> error ("broadcast: unexpected response: " <> show msg)
              s <- getState
              info ("About to sleep, state " <> textShow s)
              sleep 10_000
              s <- getState
              info ("Awake again, state: " <> textShow s)
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

      sendTest
        testHandle
        0
        ( Message
            { src = "c1"
            , dest = "n1"
            , msgId = Just 2
            , body = Read
            }
        )

      respondTest
        testHandle
        0
        ( Response
            { src = "n1"
            , dest = "c1"
            , msgId = Just 4
            , inReplyTo = 2
            , body = Read_Ok [42]
            }
        )

      advanceTime testHandle 4_000_000

------------------------------------------------------------------------

unit_simTestBroadcast :: IO Bool
unit_simTestBroadcast = unit_simTestBroadcast' Nothing

unit_simTestBroadcastReplay :: Int -> IO Bool
unit_simTestBroadcastReplay seed = unit_simTestBroadcast' (Just seed)

unit_simTestBroadcast' :: Maybe Int -> IO Bool
unit_simTestBroadcast' mSeed =
  simulationTestWith
    config
    broadcast
    initialState
    (broadcastWorkload config)
  where
    config =
      defaultTestConfig
        { replaySeed = mSeed
        , numberOfTests = 100
        , numberOfNodes = 2
        , disableShrinking = True
        , maxSize = 3
        }

broadcastWorkload ::
  TestConfig -> Workload BroadcastInput BroadcastOutput
broadcastWorkload testConfig =
  Workload
    { name = "broadcast"
    , generate = generate (-1)
    , finallyGenerate = Just (10_000_000, generateFinalReads)
    , property = HistoryPredicate historyPredicate
    , baseLatency = 200_000 -- 200 ms
    }
  where
    historyPredicate ::
      [Outgoing BroadcastInput BroadcastOutput] -> PropertyResult
    historyPredicate outgoing =
      case find (\finalRead -> Set.toList broadcasted /= finalRead) finalReads of
        Nothing -> Pass
        Just finalRead ->
          Fail
            ( show finalRead
                <> " /= "
                <> show (Set.toList broadcasted)
                -- <> "\nTrace predicate outgoing (for debugging only):"
                -- <> Text.unpack (Text.unlines (map (displayOutgoing epoch) outgoing))
            )
      where
        broadcasted :: Set Int
        broadcasted =
          foldMap
            ( \(request, mResponse) -> case mResponse of
                Nothing -> Set.empty
                Just response -> case request of
                  Message {body = Broadcast value} -> Set.singleton value
                  _ -> Set.empty
            )
            (pairReplies outgoing)

        finalReads :: [[Int]]
        finalReads =
          foldMap
            ( \case
                OutResponse (Response {body = Read_Ok values}) -> [values]
                _otherwise -> []
            )
            (take testConfig.numberOfNodes (reverse outgoing))

    allNodes :: [NodeId]
    allNodes = map makeNodeId [1 .. testConfig.numberOfNodes]

    generate :: Int -> Gen [Message BroadcastInput]
    generate (-1) = do
      let initMessages =
            map
              ( \nodeId ->
                  Message
                    { src = "c0"
                    , dest = nodeId
                    , msgId = Nothing
                    , body = Init nodeId (allNodes \\ [nodeId])
                    }
              )
              allNodes
      let topologyMessages =
            [ Message
              { src = "c0"
              , dest = nodeId
              , msgId = Nothing
              , body = Topology (gridTopology allNodes)
              }
            | nodeId <- allNodes
            ]
      inputs <- generate 0
      return (initMessages ++ topologyMessages ++ inputs)
    generate n = sized (go n [])
      where
        go n acc 0 = return (reverse acc)
        go n acc sz = do
          input <- frequency [(7, pure (Broadcast n)), (3, pure Read)]
          let n' = case input of
                Broadcast {} -> n + 1
                _otherwise -> n
          dest <- elements allNodes
          go
            n'
            ( Message {src = "c1", dest = dest, msgId = Nothing, body = input} : acc
            )
            (sz - 1)

    generateFinalReads :: Gen [Message BroadcastInput]
    generateFinalReads =
      return
        $ map
          ( \nodeId ->
              Message
                { src = "c1"
                , dest = nodeId
                , msgId = Nothing
                , body = Read
                }
          )
          allNodes

------------------------------------------------------------------------

-- | Arrange nodes in a square grid topology, such that each node has at most four neighbours.
gridTopology :: [NodeId] -> Map NodeId [NodeId]
gridTopology nodes =
  Map.fromList
    [ ( n
      , concat
          [ node (i + 1) j
          , node (i - 1) j
          , node i (j + 1)
          , node i (j - 1)
          ]
      )
    | i <- [0 .. side - 1]
    , j <- [0 .. side - 1]
    , n <- node i j
    ]
  where
    len :: Int
    len = length nodes

    side :: Int
    side = ceiling (sqrt (fromIntegral len))

    node :: Int -> Int -> [NodeId]
    node i j
      | 0 <= idx && idx < len = [nodes !! idx]
      | otherwise = []
      where
        idx :: Int
        idx = i * side + j

totalTopology :: [NodeId] -> Map NodeId [NodeId]
totalTopology nodes = Map.fromList [(node, nodes \\ [node]) | node <- nodes]
