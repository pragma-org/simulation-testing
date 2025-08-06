module Moskstraumen.Example.Broadcast (module Moskstraumen.Example.Broadcast) where

import Control.Concurrent (forkIO, killThread)
import Control.Exception (bracket)
import Data.Aeson (FromJSON, ToJSON)
import Data.List (delete, intersect, (\\))
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import qualified Data.Text as Text

import Moskstraumen.Experiment.Node8
import Moskstraumen.Fault
import Moskstraumen.Generate
import Moskstraumen.Message3
import Moskstraumen.NodeId
import Moskstraumen.Prelude
import Moskstraumen.Simulate2
import Moskstraumen.Time
import Moskstraumen.Topology

------------------------------------------------------------------------

data BroadcastInput
  = Init {node_id :: NodeId, node_ids :: [NodeId]}
  | Topology {topology :: Map NodeId [NodeId]}
  | Broadcast {message :: Int}
  | Read
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data BroadcastOutput
  = Init_Ok
  | Topology_Ok
  | Broadcast_Ok
  | Read_Ok {messages :: [Int]}
  deriving stock (Eq, Ord, Show, Generic)
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
                $ \case
                  Broadcast_Ok -> do
                    info ("Got ack from: " <> unNodeId nodeId)
                    modifyState
                      (\s -> s {unAcked = Map.adjust (delete nodeId) msg s.unAcked})
                  msg -> error ("broadcast: unexpected response: " <> show msg)
              s <- getState
              info ("About to sleep, state " <> textShow s)
              sleep 1_000_000 $ do
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
        , numberOfNodes = 5
        , disableShrinking = True
        , verboseOnSuccess = False
        , minSize = 10
        , maxSize = 30
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
    historyPredicate outgoing
      | length finalReads /= testConfig.numberOfNodes =
          Fail
            ( "Expected "
                <> show testConfig.numberOfNodes
                <> " final reads, but only got "
                <> show (length finalReads)
            )
      | otherwise =
          let expected = [0 .. maxSuccessfulBroadcast]
          in  case find
                (\finalRead -> expected /= finalRead)
                finalReads of
                Nothing -> Pass
                Just finalRead ->
                  Fail
                    ( show finalRead
                        <> " /= "
                        <> show expected
                        <> ", missing: "
                        <> show (expected \\ (finalRead `intersect` expected))
                        -- <> "\nTrace predicate outgoing (for debugging only):"
                        -- <> Text.unpack (Text.unlines (map (displayOutgoing epoch) outgoing))
                    )
      where
        -- NOTE: that [0..-1] == [], which is what we want in the finalRead
        -- comparison above.
        maxSuccessfulBroadcast :: Int
        maxSuccessfulBroadcast
          | Set.null broadcasted = -1
          | otherwise = maximum broadcasted

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
            (take (testConfig.numberOfNodes * 2) (reverse outgoing))

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
              , -- , body = Topology (gridTopology allNodes)
                body = Topology (treeTopology 4 allNodes)
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

unit_btest :: IO Bool
unit_btest = do
  let config =
        defaultTestConfig
          { replaySeed = Just 1047159807563293908
          , numberOfNodes = 2
          }
  regressionTestWith
    config
    broadcast
    initialState
    (broadcastWorkload config).property
    program
  where
    program :: [(Time, Incoming BroadcastInput BroadcastOutput)]
    program =
      [
        ( read "1970-01-01 00:00:00.445538 UTC"
        , InMessage
            ( Message
                { src = "c0"
                , dest = "n1"
                , msgId = Just 0
                , body = Init {node_id = "n1", node_ids = ["n2"]}
                }
            )
        )
      ,
        ( read "1970-01-01 00:00:01.104663 UTC"
        , InMessage
            ( Message
                { src = "c0"
                , dest = "n2"
                , msgId = Just 1
                , body = Init {node_id = "n2", node_ids = ["n1"]}
                }
            )
        )
      ,
        ( read "1970-01-01 00:00:01.4 UTC"
        , InFault (PartitionFault (Split Single ["n1"]))
        )
      ,
        ( read "1970-01-01 00:00:01.605313 UTC"
        , InMessage
            ( Message
                { src = "c1"
                , dest = "n2"
                , msgId = Just 4
                , body = Broadcast {message = 0}
                }
            )
        )
      , -- XXX: Why is this message to n2 needed? (Doesn't seem to matter what
        -- the body is, but it does matter that n2 is the dest)

        ( read "1970-01-01 00:00:01.932328 UTC"
        , InMessage
            (Message {src = "c1", dest = "n2", msgId = Just 5, body = Read})
        )
      ,
        ( read "1970-01-01 00:00:02 UTC"
        , InFault (PartitionFault None)
        )
      ,
        ( read "1970-01-01 00:00:02.378725 UTC"
        , InMessage
            ( Message
                { src = "c1"
                , dest = "n2"
                , msgId = Just 6
                , body = Broadcast {message = 1}
                }
            )
        )
      ,
        ( read "1970-01-01 00:00:12.728164 UTC"
        , InMessage
            (Message {src = "c1", dest = "n1", msgId = Just 7, body = Read})
        )
      ,
        ( read "1970-01-01 00:00:12.828164 UTC"
        , InMessage
            (Message {src = "c1", dest = "n2", msgId = Just 8, body = Read})
        )
      ]

unit_btest2 :: IO Bool
unit_btest2 = do
  let config =
        defaultTestConfig
          { replaySeed = Just 4894465900423837377
          , numberOfNodes = 2
          }
  regressionTestWith
    config
    broadcast
    initialState
    (broadcastWorkload config).property
    program
  where
    program :: [(Time, Incoming BroadcastInput BroadcastOutput)]
    program =
      [
        ( read "1970-01-01 00:00:00.057553 UTC"
        , InMessage
            ( Message
                { src = "c0"
                , dest = "n1"
                , msgId = Just 0
                , body = Init {node_id = "n1", node_ids = ["n2"]}
                }
            )
        )
      ,
        ( read "1970-01-01 00:00:00.415157 UTC"
        , InMessage
            ( Message
                { src = "c0"
                , dest = "n2"
                , msgId = Just 1
                , body = Init {node_id = "n2", node_ids = ["n1"]}
                }
            )
        )
      ,
        ( read "1970-01-01 00:00:00.578764 UTC"
        , InMessage
            ( Message
                { src = "c1"
                , dest = "n1"
                , msgId = Just 2
                , body = Broadcast {message = 0}
                }
            )
        )
      ,
        ( read "1970-01-01 00:00:01.013294 UTC"
        , InMessage
            ( Message
                { src = "c1"
                , dest = "n2"
                , msgId = Just 3
                , body = Broadcast {message = 1}
                }
            )
        )
      ,
        ( read "1970-01-01 00:00:11.469462 UTC"
        , InMessage
            (Message {src = "c1", dest = "n1", msgId = Just 4, body = Read})
        )
      ,
        ( read "1970-01-01 00:00:11.569462 UTC"
        , InMessage
            (Message {src = "c1", dest = "n2", msgId = Just 5, body = Read})
        )
      ]

unit_btest3 :: IO Bool
unit_btest3 = do
  let config =
        defaultTestConfig
          { replaySeed = Just 1249130125818355095
          , numberOfNodes = 5
          }
  regressionTestWith
    config
    broadcast
    initialState
    (broadcastWorkload config).property
    program
  where
    program :: [(Time, Incoming BroadcastInput BroadcastOutput)]
    program =
      [
        ( read "1970-01-01 00:00:00.011766 UTC"
        , InMessage
            ( Message
                { src = "c0"
                , dest = "n1"
                , msgId = Just 0
                , body = Init {node_id = "n1", node_ids = ["n2", "n3", "n4", "n5"]}
                }
            )
        )
      ,
        ( read "1970-01-01 00:00:00.042117 UTC"
        , InMessage
            ( Message
                { src = "c0"
                , dest = "n2"
                , msgId = Just 1
                , body = Init {node_id = "n2", node_ids = ["n1", "n3", "n4", "n5"]}
                }
            )
        )
      ,
        ( read "1970-01-01 00:00:00.45681 UTC"
        , InMessage
            ( Message
                { src = "c0"
                , dest = "n3"
                , msgId = Just 2
                , body = Init {node_id = "n3", node_ids = ["n1", "n2", "n4", "n5"]}
                }
            )
        )
      ,
        ( read "1970-01-01 00:00:01.866705 UTC"
        , InMessage
            ( Message
                { src = "c0"
                , dest = "n4"
                , msgId = Just 3
                , body = Init {node_id = "n4", node_ids = ["n1", "n2", "n3", "n5"]}
                }
            )
        )
      ,
        ( read "1970-01-01 00:00:02 UTC"
        , InFault (PartitionFault (Split Majority ["n1", "n2", "n3"]))
        )
      ,
        ( read "1970-01-01 00:00:02.234879 UTC"
        , InMessage
            ( Message
                { src = "c0"
                , dest = "n5"
                , msgId = Just 4
                , body = Init {node_id = "n5", node_ids = ["n1", "n2", "n3", "n4"]}
                }
            )
        )
      ,
        ( read "1970-01-01 00:00:02.828689 UTC"
        , InMessage
            ( Message
                { src = "c0"
                , dest = "n1"
                , msgId = Just 5
                , body =
                    Topology
                      { topology =
                          Map.fromList
                            [ ("n1", ["n4", "n2"])
                            , ("n2", ["n5", "n3", "n1"])
                            , ("n3", ["n4", "n2"])
                            , ("n4", ["n1", "n5", "n3"])
                            ,
                              ( "n5"
                              ,
                                [ "n2"
                                , "n4"
                                ]
                              )
                            ]
                      }
                }
            )
        )
      ,
        ( read "1970-01-01 00:00:02.954377 UTC"
        , InMessage
            ( Message
                { src = "c0"
                , dest = "n2"
                , msgId = Just 6
                , body =
                    Topology
                      { topology =
                          Map.fromList
                            [ ("n1", ["n4", "n2"])
                            , ("n2", ["n5", "n3", "n1"])
                            , ("n3", ["n4", "n2"])
                            , ("n4", ["n1", "n5", "n3"])
                            ,
                              ( "n5"
                              ,
                                [ "n2"
                                , "n4"
                                ]
                              )
                            ]
                      }
                }
            )
        )
      ,
        ( read "1970-01-01 00:00:03.452165 UTC"
        , InMessage
            ( Message
                { src = "c0"
                , dest = "n3"
                , msgId = Just 7
                , body =
                    Topology
                      { topology =
                          Map.fromList
                            [ ("n1", ["n4", "n2"])
                            , ("n2", ["n5", "n3", "n1"])
                            , ("n3", ["n4", "n2"])
                            , ("n4", ["n1", "n5", "n3"])
                            , ("n5", ["n2", "n4"])
                            ]
                      }
                }
            )
        )
      ,
        ( read "1970-01-01 00:00:03.464941 UTC"
        , InMessage
            ( Message
                { src = "c0"
                , dest = "n4"
                , msgId = Just 8
                , body =
                    Topology
                      { topology =
                          Map.fromList
                            [ ("n1", ["n4", "n2"])
                            , ("n2", ["n5", "n3", "n1"])
                            , ("n3", ["n4", "n2"])
                            , ("n4", ["n1", "n5", "n3"])
                            , ("n5", ["n2", "n4"])
                            ]
                      }
                }
            )
        )
      ,
        ( read "1970-01-01 00:00:03.525122 UTC"
        , InMessage
            ( Message
                { src = "c0"
                , dest = "n5"
                , msgId = Just 9
                , body =
                    Topology
                      { topology =
                          Map.fromList
                            [ ("n1", ["n4", "n2"])
                            , ("n2", ["n5", "n3", "n1"])
                            , ("n3", ["n4", "n2"])
                            , ("n4", ["n1", "n5", "n3"])
                            , ("n5", ["n2", "n4"])
                            ]
                      }
                }
            )
        )
      ,
        ( read "1970-01-01 00:00:03.540268 UTC"
        , InMessage
            ( Message
                { src = "c1"
                , dest = "n4"
                , msgId = Just 10
                , body = Broadcast {message = 0}
                }
            )
        )
      ,
        ( read "1970-01-01 00:00:03.575754 UTC"
        , InMessage
            ( Message
                { src = "c1"
                , dest = "n2"
                , msgId = Just 11
                , body = Broadcast {message = 1}
                }
            )
        )
      ,
        ( read "1970-01-01 00:00:04.491381 UTC"
        , InMessage
            (Message {src = "c1", dest = "n5", msgId = Just 12, body = Read})
        )
      ,
        ( read "1970-01-01 00:00:04.895583 UTC"
        , InMessage
            ( Message
                { src = "c1"
                , dest = "n2"
                , msgId = Just 13
                , body = Broadcast {message = 2}
                }
            )
        )
      ,
        ( read "1970-01-01 00:00:05 UTC"
        , InFault (PartitionFault None)
        )
      ,
        ( read "1970-01-01 00:00:05.179292 UTC"
        , InMessage
            ( Message
                { src = "c1"
                , dest = "n2"
                , msgId = Just 14
                , body = Broadcast {message = 3}
                }
            )
        )
      ,
        ( read "1970-01-01 00:00:05.309916 UTC"
        , InMessage
            ( Message
                { src = "c1"
                , dest = "n2"
                , msgId = Just 15
                , body = Broadcast {message = 4}
                }
            )
        )
      ,
        ( read "1970-01-01 00:00:15.508996 UTC"
        , InMessage
            (Message {src = "c1", dest = "n1", msgId = Just 16, body = Read})
        )
      ,
        ( read "1970-01-01 00:00:15.977401 UTC"
        , InMessage
            (Message {src = "c1", dest = "n2", msgId = Just 17, body = Read})
        )
      ,
        ( read "1970-01-01 00:00:16.543683 UTC"
        , InMessage
            (Message {src = "c1", dest = "n3", msgId = Just 18, body = Read})
        )
      ,
        ( read "1970-01-01 00:00:16.675896 UTC"
        , InMessage
            (Message {src = "c1", dest = "n4", msgId = Just 19, body = Read})
        )
      ,
        ( read "1970-01-01 00:00:16.735482 UTC"
        , InMessage
            (Message {src = "c1", dest = "n5", msgId = Just 20, body = Read})
        )
      ]
