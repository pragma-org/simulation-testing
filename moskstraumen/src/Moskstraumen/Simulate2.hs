{-# LANGUAGE FlexibleContexts #-}

module Moskstraumen.Simulate2 (module Moskstraumen.Simulate2) where

import Control.Exception
import Data.Aeson (GFromJSON, GToJSON', Value, Zero, encode)
import qualified Data.ByteString.Lazy.Char8 as LBS8
import qualified Data.List as List
import qualified Data.List.NonEmpty as NonEmpty
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (maybeToList)
import Data.Ord (comparing)
import qualified Data.Text as Text
import qualified Data.Text.IO as Text
import GHC.Generics (Rep)
import System.Timeout
import Text.Printf

-- import Moskstraumen.Codec

import Data.Vector (Vector)
import qualified Data.Vector as Vector
import Moskstraumen.Experiment.Node8
import Moskstraumen.Generate
import Moskstraumen.Heap (Heap)
import qualified Moskstraumen.Heap as Heap

-- import Moskstraumen.LinearTemporalLogic
import Moskstraumen.Message3

-- import Moskstraumen.NodeHandle

import Moskstraumen.Debugger.State
import Moskstraumen.Fault
import Moskstraumen.Metrics as Metrics
import Moskstraumen.NodeId
import Moskstraumen.Prelude
import Moskstraumen.Random
import Moskstraumen.Shrink
import Moskstraumen.Time

------------------------------------------------------------------------

-- start snippet World
data World i o = World
  { nodes :: Map NodeId (NodeHandle i o)
  , messages :: Heap Time (Incoming i o)
  , prng :: Prng
  , history :: History i o
  , journal :: Journal
  , partition :: Partition
  , metrics :: Metrics
  }

type Journal = Vector DebugEvent

-- end snippet

-- start snippet History
type History i o = [(Time, Outgoing i o)]

emptyHistory :: History i o
emptyHistory = mempty

-- end snippet

-- start snippet Deployment
data Deployment i o = Deployment
  { numberOfNodes :: Int
  , spawn :: IO (NodeHandle i o)
  }

-- end snippet

type NumberOfTests = Int

-- start snippet TestConfig
data TestConfig = TestConfig
  { numberOfTests :: Int
  , numberOfNodes :: Int
  , replaySeed :: Maybe Int
  , disableShrinking :: Bool
  , verboseOnSuccess :: Bool
  , minSize :: Int
  , maxSize :: Int
  }

-- end snippet

-- start snippet defaultTestConfig
defaultTestConfig :: TestConfig
defaultTestConfig =
  TestConfig
    { numberOfTests = 100
    , numberOfNodes = 5
    , replaySeed = Nothing
    , disableShrinking = False
    , verboseOnSuccess = False
    , minSize = 0
    , maxSize = 100
    }

-- end snippet

------------------------------------------------------------------------

generateRandomArrivalTimes ::
  Time
  -> Double
  -> [Incoming i o]
  -> Prng
  -> (([(Time, Incoming i o)], Time), Prng)
generateRandomArrivalTimes time0 meanMicros = go time0 0 []
  where
    go time _i acc [] prng = ((reverse acc, time), prng)
    go time i acc (message : messages) prng =
      let
        (deltaMicros, prng') = exponential meanMicros prng
        arrivalTime = addTimeMicros (round deltaMicros) time
      in
        go arrivalTime (i + 1) ((arrivalTime, message) : acc) messages prng'

-- start snippet stepWorld

data StepSuccess i o
  = StepDone
  | StepContinue (World i o)

data StepFailure
  = StepSomeException SomeException
  | StepUnknownDestination NodeId
  | StepTimeoutWhenHandling String
  | StepTooManySteps

data StepResult i o
  = StepFailure StepFailure
  | StepSuccess (StepSuccess i o)

stepWorld ::
  (Show i, Show o, Ord i, Ord o) => World i o -> IO (StepResult i o)
stepWorld world = do
  case Heap.pop world.messages of
    Nothing -> return (StepSuccess StepDone)
    Just ((arrivalTime, incoming), messages') -> do
      case incoming of
        InTimer nodeId -> case Map.lookup nodeId world.nodes of
          Nothing ->
            return
              ( StepFailure
                  (StepUnknownDestination nodeId)
              )
          Just nodeHandle -> do
            handleOutput <- nodeHandle.advanceToTime arrivalTime
            mTime <- nodeHandle.nextTimer
            let (clientResponses, nodeMessages) =
                  List.partition (isClientNodeId . (.dest)) handleOutput.outgoing
            -- XXX: Make this configurable via workload?
            let meanMicros = 200_000 -- 200ms
            let ((nodeMessages', _time), prng') =
                  generateRandomArrivalTimes
                    arrivalTime
                    meanMicros
                    (map outgoingToIncoming nodeMessages)
                    world.prng
            return
              $ StepSuccess
              $ StepContinue
                World
                  { nodes = world.nodes
                  , messages =
                      -- NOTE: only add timer event if there already isn't one.
                      messages'
                        `Heap.union` Heap.fromList
                          ( (map (\time -> (time, InTimer nodeId)) (maybeToList mTime))
                              ++ nodeMessages'
                          )
                  , prng = prng'
                  , -- XXX: the arrival time for client responses is arbitrary
                    history =
                      world.history
                        ++ map
                          ( \clientResponse -> (addTimeMicros (round meanMicros) arrivalTime, clientResponse)
                          )
                          clientResponses
-- end snippet
                  , journal =
                      world.journal
                        <> Vector.singleton
                          ( DebugEvent
                              { state =
                                  "Node: "
                                    <> unNodeId incoming.dest
                                    <> "\nBefore: "
                                    <> handleOutput.beforeState
                                    <> "\nAfter:  "
                                    <> handleOutput.afterState
                              , currentEvent =
                                  SendEvent
                                    { from = unNodeId incoming.src
                                    , to = unNodeId incoming.dest
                                    , event =
                                        Text.takeWhile (/= ' ') (either textShow textShow incoming.body)
                                    , receivedLogical = Vector.length world.journal
                                    , message =
                                        either textShow textShow incoming.body
                                    }
                              , logs = handleOutput.logs
                              , sent =
                                  zipWith
                                    ( \ix outgoing ->
                                        SendEvent
                                          { from = unNodeId outgoing.src
                                          , to = unNodeId outgoing.dest
                                          , event = Text.takeWhile (/= ' ') (either textShow textShow outgoing.body)
                                          , receivedLogical =
                                              length handleOutput.outgoing + Vector.length world.journal + ix -- XXX: doesn't account for other sent...
                                          , message = either textShow textShow outgoing.body
                                          }
                                    )
                                    [0 ..]
                                    handleOutput.outgoing
                              , receivedTime = fromIntegral (diffTimeMicros arrivalTime epoch * 1000)
                              }
                          )
                  , partition = world.partition
                  , metrics = world.metrics
-- start snippet stepWorld
                  }
        InFault fault@(PartitionFault partition) ->
          return
            ( StepSuccess
                ( StepContinue
                    world
                      { partition
                      , messages = messages'
                      , history = world.history <> [(arrivalTime, OutFault fault)]
-- end snippet
                      , metrics =
                          world.metrics
                            { partitions =
                                world.metrics.partitions + (if partition == None then 0 else 1)
                            }
-- start snippet stepWorld
                      }
                )
            )
        -- XXX: enable faults:
        _otherwise
          | affected incoming.src incoming.dest world.partition -> do
              -- putStrLn
              --   ( "Dropping: " <> show incoming <> ", partition: " <> show world.partition
              --   )
              return
                ( StepSuccess
                    ( StepContinue
                        world
                          { messages = messages'
                          , history =
                              world.history <> [(arrivalTime, Dropped incoming)]
                          , metrics =
                              world.metrics {droppedMessages = world.metrics.droppedMessages + 1}
                          }
                    )
                )
        _otherwise ->
          case Map.lookup incoming.dest world.nodes of
            Nothing ->
              return
                ( StepFailure
                    (StepUnknownDestination incoming.dest)
                )
            Just nodeHandle ->
              timeout 5_000_000 (try (nodeHandle.handle arrivalTime incoming)) >>= \case
                Nothing ->
                  return
                    ( StepFailure
                        (StepTimeoutWhenHandling (show incoming))
                    )
                Just (Left err) -> do
                  putStrLn
                    ( "stepWorld, failed on: "
                        <> show (arrivalTime, incoming, messages')
                    )
                  return (StepFailure (StepSomeException err))
                Just (Right handleOutput) -> do
                  -- mapM_ Text.putStrLn handleOutput.logs
                  let (clientResponses, nodeMessages) =
                        List.partition (isClientNodeId . (.dest)) handleOutput.outgoing
                  let meanMicros = 20000 -- 20ms
                  let ((nodeMessages', _time), prng') =
                        generateRandomArrivalTimes
                          arrivalTime
                          meanMicros
                          (map outgoingToIncoming nodeMessages)
                          world.prng
                  mTime <- nodeHandle.nextTimer
                  -- XXX: code duplication from above...
                  return
                    $ StepSuccess
                    $ StepContinue
                      World
                        { nodes = world.nodes
                        , messages =
                            messages'
                              `Heap.union` Heap.fromList
                                ( (map (\time -> (time, InTimer incoming.dest)) (maybeToList mTime))
                                    ++ nodeMessages'
                                )
                        , prng = prng'
                        , -- XXX: the arrival time for client responses is arbitrary
                          history =
                            world.history ++ (arrivalTime, incomingToOutgoing incoming)
                              : map
                                ( \clientResponse -> (addTimeMicros (round meanMicros) arrivalTime, clientResponse)
                                )
                                clientResponses
-- end snippet
                          journal =
                            world.journal
                              <> Vector.singleton
                                ( DebugEvent
                                    { state =
                                        "Node: "
                                          <> unNodeId incoming.dest
                                          <> "\nBefore: "
                                          <> handleOutput.beforeState
                                          <> "\nAfter:  "
                                          <> handleOutput.afterState
                                    , currentEvent =
                                        SendEvent
                                          { from = unNodeId incoming.src
                                          , to = unNodeId incoming.dest
                                          , event =
                                              Text.takeWhile (/= ' ') (either textShow textShow incoming.body)
                                          , receivedLogical = Vector.length world.journal
                                          , message =
                                              either textShow textShow incoming.body
                                          }
                                    , logs = handleOutput.logs
                                    , sent =
                                        zipWith
                                          ( \ix outgoing ->
                                              SendEvent
                                                { from = unNodeId outgoing.src
                                                , to = unNodeId outgoing.dest
                                                , event = Text.takeWhile (/= ' ') (either textShow textShow outgoing.body)
                                                , receivedLogical =
                                                    length handleOutput.outgoing + Vector.length world.journal + ix -- XXX: doesn't account for other sent...
                                                , message = either textShow textShow outgoing.body
                                                }
                                          )
                                          [0 ..]
                                          handleOutput.outgoing
                                    , receivedTime = fromIntegral (diffTimeMicros arrivalTime epoch * 1000)
                                    }
                                )
                        , partition = world.partition
                        , metrics = world.metrics
                        -- start snippet stepWorld
                        }

-- end snippet

displayStepFailure :: StepFailure -> String
displayStepFailure (StepSomeException err) = displayException err
displayStepFailure (StepUnknownDestination nodeId) =
  "unknown destination node: " <> Text.unpack (unNodeId nodeId)
displayStepFailure (StepTimeoutWhenHandling incoming) =
  "timeout when handling: " <> incoming
displayStepFailure StepTooManySteps = "too many steps"

-- start snippet runWorld
runWorld ::
  (Show i, Show o, Ord i, Ord o) =>
  World i o
  -> IO (Maybe StepFailure, World i o)
runWorld = go 1000000
  where
    go 0 world = return (Just StepTooManySteps, world)
    go n world =
      stepWorld world >>= \case
        StepSuccess StepDone -> return (Nothing, world)
        StepSuccess (StepContinue world') -> go (n - 1) world'
        StepFailure err -> return (Just err, world)

-- end snippet

-- start snippet newWorld
newWorld ::
  Deployment i o -> Heap Time (Incoming i o) -> Prng -> IO (World i o)
newWorld deployment initialMessages prng = do
  let nodeIds = map makeNodeId [1 .. deployment.numberOfNodes]
  nodeHandles <- replicateM deployment.numberOfNodes deployment.spawn
  return
    World
      { nodes = Map.fromList (zip nodeIds nodeHandles)
      , messages = initialMessages
      , prng = prng
      , history = []
      , journal = Vector.empty
      , partition = None
      , metrics = emptyMetrics
      }

-- end snippet

------------------------------------------------------------------------

-- start snippet TestResult
data TestResult i o
  = Success [History i o] Metrics
  | Failure [(Time, Incoming i o)] (History i o) (Vector DebugEvent) Reason
  -- end snippet
  deriving stock (Eq, Show)

type Reason = String

handleResult ::
  (Show i, Show o) =>
  TestResult i o
  -> Seed
  -> IO Bool
handleResult (Failure (List.sortBy (comparing fst) -> program) history journal reason) seed = do
  putStrLn "Program:"
  putStrLn ""
  putStr "  ["
  mapM_
    ( \(time, incoming) ->
        Text.putStr
          ( " (read \""
              <> textShow time
              <> "\",\n     "
              <> textShow incoming
              <> ")\n  ,"
          )
    )
    (take (length program - 1) program)
  let (lastTime, lastIncoming) = last program
  Text.putStrLn
    ( " (read \""
        <> textShow lastTime
        <> "\",\n     "
        <> textShow lastIncoming
        <> ")"
    )
  putStrLn "  ]"
  putStrLn ""

  putStrLn "History:"
  mapM_
    ( Text.putStrLn
        . ( \(index, (time, message)) ->
              Text.pack (printf "%3d" index)
                <> ". "
                <> displayOutgoing time message
          )
    )
    (zip [1 :: Int ..] history)
  putStrLn ""
  putStrLn ("Seed: " <> show seed)
  putStrLn ""
  putStrLn ("Failure: " <> reason)
  -- BUG: calls .src/.dest/.body on InTimer, which doesn't make sense?
  -- putStrLn "Debug journal: /tmp/moskstraumen.journal"
  -- LBS8.writeFile "/tmp/moskstraumen.journal" (encode journal)
  return False
handleResult (Success histories metrics) _seed = do
  forM_ (zip [1 :: Int ..] histories) $ \(historyIndex, history) -> do
    putStrLn ("\nHistory #" <> show historyIndex <> ":\n")
    mapM_
      ( Text.putStrLn
          . ( \(index, (time, message)) ->
                Text.pack (printf "%3d" index)
                  <> ". "
                  <> displayOutgoing time message
            )
      )
      (zip [1 :: Int ..] history)
  putStrLn ""
  Text.putStrLn (displayMetrics metrics)
  putStrLn ""
  putStrLn "Success!"
  return True

displayOutgoing :: (Show i, Show o) => Time -> Outgoing i o -> Text
displayOutgoing time (OutMessage (Message {src, dest, body})) =
  Text.concat
    [ unNodeId src
    , if isClientNodeId src then " ==> " else " --> "
    , unNodeId dest
    , "   "
    , displayTime time
    , "   " <> textShow body
    ]
displayOutgoing time (OutResponse (Response {src, dest, body})) =
  Text.concat
    [ unNodeId dest
    , if isClientNodeId dest then " <== " else " <-- "
    , unNodeId src
    , "   "
    , displayTime time
    , "   " <> textShow body
    ]
displayOutgoing time (OutFault fault) =
  Text.concat
    [ "            "
    , displayTime time
    , "   " <> textShow fault
    ]
displayOutgoing time (Dropped incoming) =
  Text.concat
    [ unNodeId incoming.dest
    , if isClientNodeId incoming.dest then " </= " else " </- "
    , unNodeId incoming.src
    , "   "
    , displayTime time
    , "   " <> textShow incoming.body
    ]
displayOutgoing _time (OutRpcError _err) = undefined

-- start snippet Workload

data Property i o
  = -- LTL (Form Message)
    HistoryPredicate ([Outgoing i o] -> PropertyResult)

data PropertyResult = Pass | Fail String

(===) :: (Show a, Eq a) => a -> a -> PropertyResult
x === y
  | x == y = Pass
  | otherwise = Fail (show x <> " /= " <> show y)

data Workload i o = Workload
  { name :: Text
  , generate :: Gen [Message i]
  , finallyGenerate :: Maybe (Int, Gen [Message i])
  , property :: Property i o
  , baseLatency :: Double -- µs
  }

-- end snippet

-- start snippet runTest
data RunMode = TestMode | ShrinkMode
  deriving (Eq)

runTest ::
  (Show i, Show o, Ord i, Ord o) =>
  TestConfig
  -> Deployment i o
  -> Property i o
  -> Prng
  -> RunMode
  -> [(Time, Incoming i o)]
  -> IO (TestResult i o)
runTest testConfig deployment property prng runMode program = do
  world <-
    newWorld
      deployment
      (Heap.fromList program)
      prng
  runWorld world `finally` traverse_ (.close) world.nodes >>= \case
    (Just err, world') ->
      return
        (Failure program world'.history world'.journal (displayStepFailure err))
    (Nothing, world') -> do
      let propertyResult = case property of
            -- XXX: we are throwing away arrival times here, we should use them in the LTL checker!
            -- LTL formula ->
            --   if sat formula (map snd history) emptyEnv
            --     then Pass
            --     else Fail "LTL formula failed"
            HistoryPredicate predicate -> predicate (map snd world'.history)
      case propertyResult of
        Pass -> do
          when (runMode == ShrinkMode)
            $ putStr "."
          return
            ( Success
                (if testConfig.verboseOnSuccess then [world'.history] else [])
                world'.metrics
            )
        Fail reason -> do
          when (runMode == ShrinkMode)
            $ putStr "x"
          return (Failure program world'.history world'.journal reason)

-- end snippet

-- start snippet runTests
runTests ::
  forall i o.
  (Show i, Show o, Ord i, Ord o) =>
  TestConfig
  -> Deployment i o
  -> Workload i o
  -> Prng
  -> IO (TestResult i o)
runTests testConfig deployment workload initialPrng =
  loop
    testConfig.numberOfTests
    initialPrng
    initialSize
    []
    emptyMetrics
  where
    initialSize :: Int
    initialSize = 0

    loop ::
      NumberOfTests
      -> Prng
      -> Int
      -> [History i o]
      -> Metrics
      -> IO (TestResult i o)
    loop 0 _prng _size histories metrics =
      return
        ( Success
            (reverse histories)
            metrics
              { Metrics.numberOfTests = fromIntegral (testConfig.numberOfTests)
              }
        )
    loop n prng size histories metrics = do
      let (prng', incoming) = generateIncoming prng size
      let (prng'', prng''') = splitPrng prng'
      -- putStrLn
      --   "\nNEW TEST ===================================================\n"
      result <-
        runTest testConfig deployment workload.property prng'' TestMode incoming
      case result of
        Success histories' metrics' ->
          loop
            (n - 1)
            prng'''
            (((n + 3) `div` 2) `min` testConfig.maxSize `max` testConfig.minSize)
            (histories' ++ histories)
            (metrics <> metrics')
        Failure program unShrunkTrace debugTrace reason -> do
          if testConfig.disableShrinking
            then return (Failure program unShrunkTrace debugTrace reason)
            else do
              putStrLn "Shrinking:"
              let shrinker list =
                    let
                      -- NOTE: The first `numberOfNodes` messages are always
                      -- `Init` messages, and these should not be shrunk.
                      (initMessages, list') = splitAt deployment.numberOfNodes list
                    in
                      map (initMessages ++) (shrinkList (const []) list')

              shrinkSteps <-
                shrinkSimple
                  ( fmap (testResultToBool reason)
                      . runTest testConfig deployment workload.property prng ShrinkMode
                  )
                  shrinker
                  incoming
              let shrunkProgram = NonEmpty.last shrinkSteps
              assertM (program == NonEmpty.head shrinkSteps)
              -- NOTE: we need to run the shrunk program once more to get the
              -- history, etc.
              result' <-
                runTest
                  testConfig
                  deployment
                  workload.property
                  prng
                  ShrinkMode
                  shrunkProgram
              case result' of
                Success {} -> error "impossible"
                Failure {} -> do
                  putStrLn
                    ( "\nShrunk: "
                        <> show (NonEmpty.length shrinkSteps)
                        <> " times"
                    )
                  return result'

    testResultToBool :: Reason -> TestResult i o -> Bool
    testResultToBool _reason Success {} = True
    testResultToBool reason (Failure _ _ _ reason') = reason == reason'

    testResultToMaybe :: TestResult i o -> Maybe (History i o)
    testResultToMaybe Success {} = Nothing
    testResultToMaybe (Failure _program history _journal _reason) = Just history

    generateIncoming :: Prng -> Int -> (Prng, [(Time, Incoming i o)])
    generateIncoming prng size = runGen prng size $ do
      initialMessages <- workload.generate
      (initialMessages', time) <-
        liftGen
          ( generateRandomArrivalTimes
              epoch
              workload.baseLatency
              (map InMessage initialMessages)
          )
      let meanPartitionDuration = 1_000_000
      faults <-
        map (fmap InFault)
          <$> generatePartitions
            (map makeNodeId [1 .. testConfig.numberOfNodes])
            ( addTimeMicros
                (floor workload.baseLatency * testConfig.numberOfNodes * 2)
                epoch
            , time
            )
            meanPartitionDuration
      case workload.finallyGenerate of
        Nothing -> return (addMessageIds initialMessages')
        Just (delay, finallyGen) -> do
          finalMessages <- finallyGen
          (finalMessages', _time) <-
            liftGen
              ( generateRandomArrivalTimes
                  (addTimeMicros delay time)
                  workload.baseLatency
                  (map InMessage finalMessages)
              )
          return (addMessageIds (initialMessages' <> finalMessages') <> faults)

-- end snippet

------------------------------------------------------------------------

-- start snippet blackboxTest
blackboxTestWith ::
  ( Show i
  , Show o
  , Ord i
  , Ord o
  , Generic i
  , Generic o
  , GFromJSON Zero (Rep i)
  , GFromJSON Zero (Rep o)
  , GToJSON' Value Zero (Rep i)
  , GToJSON' Value Zero (Rep o)
  ) =>
  TestConfig
  -> FilePath
  -> (Seed -> [String])
  -> Workload i o
  -> IO Bool
blackboxTestWith testConfig binaryFilePath args workload = do
  (prng, seed) <- newPrng testConfig.replaySeed
  let deployment =
        Deployment
          { numberOfNodes = testConfig.numberOfNodes
          , spawn = pipeNodeHandle binaryFilePath (args seed) jsonCodec
          }
  let (prng', _prng'') = splitPrng prng
  result <- runTests testConfig deployment workload prng'
  handleResult result seed

blackboxTest ::
  ( Show i
  , Show o
  , Ord i
  , Ord o
  , Generic i
  , Generic o
  , GFromJSON Zero (Rep i)
  , GFromJSON Zero (Rep o)
  , GToJSON' Value Zero (Rep i)
  , GToJSON' Value Zero (Rep o)
  ) =>
  FilePath
  -> Workload i o
  -> IO Bool
blackboxTest binary = blackboxTestWith defaultTestConfig binary (const [])

-- end snippet

inProcessSimulationTestWith ::
  (Show state, Show input, Show output, Ord input, Ord output) =>
  TestConfig
  -> Node state input output
  -> state
  -> Workload input output
  -> IO Bool
inProcessSimulationTestWith testConfig node initialState workload = do
  (prng, seed) <- newPrng testConfig.replaySeed
  let deployment =
        Deployment
          { numberOfNodes = testConfig.numberOfNodes
          , spawn = inProcessSimulationNodeHandle node initialState
          }
  result <- runTests testConfig deployment workload prng
  handleResult result seed

inProcessSimulationTest ::
  (Show state, Show input, Show output, Ord input, Ord output) =>
  Node state input output
  -> state
  -> Workload input output
  -> IO Bool
inProcessSimulationTest = inProcessSimulationTestWith defaultTestConfig

regressionTestWith ::
  (Show state, Show input, Show output, Ord input, Ord output) =>
  TestConfig
  -> Node state input output
  -> state
  -> Property input output
  -> [(Time, Incoming input output)]
  -> IO Bool
regressionTestWith testConfig node initialState property program = do
  (prng, seed) <- newPrng testConfig.replaySeed
  let deployment =
        Deployment
          { numberOfNodes = testConfig.numberOfNodes
          , spawn = inProcessSimulationNodeHandle node initialState
          }
  result <-
    runTest
      testConfig
      deployment
      property
      prng
      TestMode
      program
  handleResult result seed

-- start snippet outOfProcessSimulationTestWith
outOfProcessSimulationTestWith ::
  ( Show input
  , Show output
  , Read input
  , Read output
  , Ord input
  , Ord output
  ) =>
  TestConfig
  -> FilePath
  -> [String]
  -> Workload input output
  -> IO Bool
outOfProcessSimulationTestWith testConfig binaryFilePath arguments workload = do
  (prng, seed) <- newPrng testConfig.replaySeed
  let deployment =
        Deployment
          { numberOfNodes = testConfig.numberOfNodes
          , spawn = simulationNodeHandle binaryFilePath arguments
          }
  result <- runTests testConfig deployment workload prng
  handleResult result seed

-- end snippet

outOfProcessSimulationTest ::
  ( Show input
  , Show output
  , Read input
  , Read output
  , Ord input
  , Ord output
  ) =>
  FilePath
  -> [String]
  -> Workload input output
  -> IO Bool
outOfProcessSimulationTest = outOfProcessSimulationTestWith defaultTestConfig
