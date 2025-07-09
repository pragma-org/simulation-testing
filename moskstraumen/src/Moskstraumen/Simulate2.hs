{-# LANGUAGE FlexibleContexts #-}

module Moskstraumen.Simulate2 (module Moskstraumen.Simulate2) where

import Control.Exception
import Data.Aeson (GFromJSON, GToJSON', Value, Zero, encode)
import qualified Data.ByteString.Lazy.Char8 as LBS8
import qualified Data.List as List
import qualified Data.List.NonEmpty as NonEmpty
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
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
  }

type Journal = Vector DebugEvent

-- end snippet

-- start snippet History
type History i o = [(Time, Outgoing i o)]

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

data StepResult i o
  = StepFailure StepFailure
  | StepSuccess (StepSuccess i o)

displayStepFailure :: StepFailure -> String
displayStepFailure (StepSomeException err) = displayException err
displayStepFailure (StepUnknownDestination nodeId) =
  "unknown destination node: " <> Text.unpack (unNodeId nodeId)
displayStepFailure (StepTimeoutWhenHandling incoming) =
  "timeout when handling: " <> incoming

stepWorld ::
  (Show i, Show o) => World i o -> IO (StepResult i o)
stepWorld world = case Heap.pop world.messages of
  Nothing -> return (StepSuccess StepDone)
  Just ((arrivalTime, incoming), messages') ->
    case incoming of
      InFault fault@(PartitionFault partition) ->
        return
          ( StepSuccess
              ( StepContinue
                  world
                    { partition
                    , messages = messages'
                    , history = world.history <> [(arrivalTime, OutFault fault)]
                    }
              )
          )
      -- XXX: enable faults:
      _otherwise
        | incoming.src
            /= "c0"
            && affected incoming.src incoming.dest world.partition -> do
            putStrLn
              ( "Dropping: " <> show incoming <> ", partition: " <> show world.partition
              )
            return
              ( StepSuccess
                  ( StepContinue
                      world
                        { messages = messages'
                        , history =
                            world.history <> [(arrivalTime, Dropped incoming)]
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
          Just node ->
            timeout 5_000_000 (try (node.handle arrivalTime incoming)) >>= \case
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
                mapM_ Text.putStrLn handleOutput.logs
                let aux :: Outgoing i o -> NodeId
                    aux outgoing = outgoing.dest
                let (clientResponses, nodeMessages) =
                      List.partition (isClientNodeId . aux) handleOutput.outgoing
                    meanMicros = 20000 -- 20ms
                    ((nodeMessages', _time), prng') =
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
                          messages' <> Heap.fromList nodeMessages'
                      , prng = prng'
                      , -- XXX: the arrival time for client responses is arbitrary
                        history =
                          world.history ++ (arrivalTime, incomingToOutgoing incoming)
                            : map
                              ( \clientResponse -> (addTimeMicros (round meanMicros) arrivalTime, clientResponse)
                              )
                              clientResponses
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
                      }

-- end snippet

-- start snippet runWorld
runWorld ::
  (Show i, Show o) =>
  World i o
  -> IO (Maybe StepFailure, History i o, Journal)
runWorld world =
  stepWorld world >>= \case
    StepSuccess StepDone -> return (Nothing, world.history, world.journal)
    StepSuccess (StepContinue world') -> runWorld world'
    StepFailure err -> return (Just err, world.history, world.journal)

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
      }

-- end snippet

------------------------------------------------------------------------

-- start snippet TestResult
data TestResult i o
  = Success
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
  putStrLn "Debug journal: /tmp/moskstraumen.journal"
  LBS8.writeFile "/tmp/moskstraumen.journal" (encode journal)
  return False
handleResult Success _seed = do
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
  (Show i, Show o) =>
  Deployment i o
  -> Workload i o
  -> Prng
  -> RunMode
  -> [(Time, Incoming i o)]
  -> IO (TestResult i o)
runTest deployment workload prng runMode program = do
  world <-
    newWorld
      deployment
      (Heap.fromList program)
      prng
  runWorld world `finally` traverse_ (.close) world.nodes >>= \case
    (Just err, history, journal) -> return (Failure program history journal (displayStepFailure err))
    (Nothing, history, journal) -> do
      let propertyResult = case workload.property of
            -- XXX: we are throwing away arrival times here, we should use them in the LTL checker!
            -- LTL formula ->
            --   if sat formula (map snd history) emptyEnv
            --     then Pass
            --     else Fail "LTL formula failed"
            HistoryPredicate predicate -> predicate (map snd history)
      case propertyResult of
        Pass -> do
          when (runMode == ShrinkMode)
            $ putStr "."
          return Success
        Fail reason -> do
          when (runMode == ShrinkMode)
            $ putStr "x"
          return (Failure program history journal reason)

-- end snippet

-- start snippet runTests
runTests ::
  forall i o.
  (Show i, Show o) =>
  TestConfig
  -> Deployment i o
  -> Workload i o
  -> Prng
  -> IO (TestResult i o)
runTests testConfig deployment workload initialPrng =
  loop testConfig.numberOfTests initialPrng initialSize
  where
    initialSize :: Int
    initialSize = 0

    loop :: NumberOfTests -> Prng -> Int -> IO (TestResult i o)
    loop 0 _prng _size = return Success
    loop n prng size = do
      let (prng', incoming) = generateIncoming prng size
      let (prng'', prng''') = splitPrng prng'
      putStrLn
        "\nNEW TEST ===================================================\n"
      result <-
        runTest deployment workload prng'' TestMode incoming
      case result of
        Success -> loop (n - 1) prng''' (min testConfig.maxSize ((n + 3) `div` 2))
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

              initialMessagesAndTrace <-
                shrink
                  (fmap testResultToMaybe . runTest deployment workload prng ShrinkMode)
                  shrinker
                  incoming
              let (_shrunkMessages, shrunkTrace) = NonEmpty.last initialMessagesAndTrace
              putStrLn
                ( "\nShrunk: "
                    <> show (NonEmpty.length initialMessagesAndTrace)
                    <> " times"
                )
              -- XXX: We need the shrunkDebugTrace here...
              return (Failure program shrunkTrace debugTrace reason)

    testResultToMaybe :: TestResult i o -> Maybe (History i o)
    testResultToMaybe Success = Nothing
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
      faults <-
        map (fmap InFault)
          <$> generatePartitions
            (map makeNodeId [1 .. testConfig.numberOfNodes])
            ( addTimeMicros
                (floor workload.baseLatency * testConfig.numberOfNodes * 2)
                epoch
            , time
            )
            (floor workload.baseLatency * 3)
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

simulationTestWith ::
  (Show state, Show input, Show output) =>
  TestConfig
  -> Node state input output
  -> state
  -> Workload input output
  -> IO Bool
simulationTestWith testConfig node initialState workload = do
  (prng, seed) <- newPrng testConfig.replaySeed
  let deployment =
        Deployment
          { numberOfNodes = testConfig.numberOfNodes
          , spawn = simulationNodeHandle node initialState
          }
  result <- runTests testConfig deployment workload prng
  handleResult result seed

simulationTest ::
  (Show state, Show input, Show output) =>
  Node state input output
  -> state
  -> Workload input output
  -> IO Bool
simulationTest = simulationTestWith defaultTestConfig

regressionTestWith ::
  (Show state, Show input, Show output) =>
  TestConfig
  -> Node state input output
  -> state
  -> Workload input output
  -> [(Time, Incoming input output)]
  -> IO Bool
regressionTestWith testConfig node initialState workload program = do
  (prng, seed) <- newPrng testConfig.replaySeed
  let deployment =
        Deployment
          { numberOfNodes = testConfig.numberOfNodes
          , spawn = simulationNodeHandle node initialState
          }
  result <-
    runTest
      deployment
      workload
      prng
      TestMode
      program
  handleResult result seed
