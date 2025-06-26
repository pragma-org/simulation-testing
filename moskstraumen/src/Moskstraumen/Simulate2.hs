{-# LANGUAGE FlexibleContexts #-}

module Moskstraumen.Simulate2 (module Moskstraumen.Simulate2) where

import Control.Exception
import Data.Aeson (GFromJSON, GToJSON', Value, Zero, encode)
import qualified Data.ByteString.Lazy.Char8 as LBS8
import Data.List (partition)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import qualified Data.Text.IO as Text
import GHC.Generics (Rep)
import System.Timeout
import Text.Printf

-- import Moskstraumen.Codec

import Data.Vector (Vector)
import qualified Data.Vector as Vector
import Moskstraumen.Experiment.Node8
import Moskstraumen.Generate (Gen)
import qualified Moskstraumen.Generate as Gen
import Moskstraumen.Heap (Heap)
import qualified Moskstraumen.Heap as Heap

-- import Moskstraumen.LinearTemporalLogic
import Moskstraumen.Message3

-- import Moskstraumen.NodeHandle

import Moskstraumen.Debugger.State
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
  -> (Prng, [(Time, Incoming i o)], Time)
generateRandomArrivalTimes time0 meanMicros = go time0 0 []
  where
    go time _i acc [] prng = (prng, reverse acc, time)
    go time i acc (message : messages) prng =
      let
        (deltaMicros, prng') = exponential meanMicros prng
        arrivalTime = addTimeMicros (round deltaMicros) time
      in
        go arrivalTime (i + 1) ((arrivalTime, message) : acc) messages prng'

-- start snippet stepWorld
stepWorld :: (Show i, Show o) => World i o -> IO (Either (World i o) ())
stepWorld world = case Heap.pop world.messages of
  Nothing -> return (Right ())
  Just ((arrivalTime, message), messages') ->
    case Map.lookup message.dest world.nodes of
      Nothing -> error ("stepWorld: unknown destination node: " ++ show message.dest)
      Just node -> do
        timeout 5_000_000 (try (node.handle arrivalTime message)) >>= \case
          Nothing ->
            error ("stepWorld: timeout when handling: " <> show message)
          Just (Left err) -> do
            putStrLn
              ( "stepWorld, failed on the message failed: "
                  <> show (arrivalTime, message, messages')
              )
            error (displayException (err :: SomeException))
          Just (Right handleOutput) -> do
            mapM_ Text.putStrLn handleOutput.logs
            let aux :: Outgoing i o -> NodeId
                aux outgoing = outgoing.dest
            let (clientResponses, nodeMessages) =
                  partition (isClientNodeId . aux) handleOutput.outgoing
                meanMicros = 20000 -- 20ms
                (prng', nodeMessages', _time) =
                  generateRandomArrivalTimes
                    arrivalTime
                    meanMicros
                    (map outgoingToIncoming nodeMessages)
                    world.prng
            return
              $ Left
                World
                  { nodes = world.nodes
                  , messages =
                      messages' <> Heap.fromList nodeMessages'
                  , prng = prng'
                  , -- XXX: the arrival time for client responses is arbitrary
                    history =
                      world.history ++ (arrivalTime, incomingToOutgoing message)
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
                                    <> unNodeId message.dest
                                    <> "\nBefore: "
                                    <> handleOutput.beforeState
                                    <> "\nAfter:  "
                                    <> handleOutput.afterState
                              , currentEvent =
                                  SendEvent
                                    { from = unNodeId message.src
                                    , to = unNodeId message.dest
                                    , event =
                                        Text.takeWhile (/= ' ') (either textShow textShow message.body)
                                    , receivedLogical = Vector.length world.journal
                                    , message =
                                        either textShow textShow message.body
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
                              , receivedTime = 0
                              }
                          )
                  }

-- end snippet

-- start snippet runWorld
runWorld ::
  (Show i, Show o) => World i o -> IO (History i o, Journal)
runWorld world =
  stepWorld world >>= \case
    Right () -> return (world.history, world.journal)
    Left world' -> runWorld world'

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
      }

-- end snippet

------------------------------------------------------------------------

-- start snippet TestResult
data TestResult i o
  = Success
  | Failure (History i o) (Vector DebugEvent) Reason
  -- end snippet
  deriving stock (Eq, Show)

type Reason = String

handleResult ::
  (Show i, Show o) =>
  TestResult i o
  -> Seed
  -> IO Bool
handleResult (Failure history journal reason) seed = do
  putStrLn "History: "
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
    , textShow time
    , "   " <> textShow body
    ]
displayOutgoing time (OutResponse (Response {src, dest, body})) =
  Text.concat
    [ unNodeId dest
    , if isClientNodeId dest then " <== " else " <-- "
    , unNodeId src
    , "   "
    , textShow time
    , "   " <> textShow body
    ]

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
runTest deployment workload prng runMode initialMessages = do
  world <-
    newWorld
      deployment
      (Heap.fromList initialMessages)
      prng
  (resultingHistory, debugTrace) <-
    runWorld world `finally` traverse_ (.close) world.nodes
  let propertyResult = case workload.property of
        -- XXX: we are throwing away arrival times here, we should use them in the LTL checker!
        -- LTL formula ->
        --   if sat formula (map snd resultingHistory) emptyEnv
        --     then Pass
        --     else Fail "LTL formula failed"
        HistoryPredicate predicate -> predicate (map snd resultingHistory)
  case propertyResult of
    Pass -> do
      when (runMode == ShrinkMode)
        $ putStr "."
      return Success
    Fail reason -> do
      when (runMode == ShrinkMode)
        $ putStr "x"
      return (Failure resultingHistory debugTrace reason)

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
      let (prng', messages) = generate size prng
      let (prng'', prng''') = splitPrng prng'
      result <-
        runTest deployment workload prng'' TestMode messages
      case result of
        Success -> loop (n - 1) prng''' (min testConfig.maxSize ((n + 3) `div` 2))
        Failure unShrunkTrace debugTrace reason -> do
          if testConfig.disableShrinking
            then return (Failure unShrunkTrace debugTrace reason)
            else do
              putStrLn "Shrinking:"
              let shrinker list =
                    let
                      (initMessages, list') = splitAt deployment.numberOfNodes list
                    in
                      map (initMessages ++) (shrinkList (const []) list')

              initialMessagesAndTrace <-
                shrink
                  (fmap testResultToMaybe . runTest deployment workload prng ShrinkMode)
                  shrinker
                  messages
              let (_shrunkMessages, shrunkTrace) = NonEmpty.last initialMessagesAndTrace
              putStrLn
                ( "\nShrunk: "
                    <> show (NonEmpty.length initialMessagesAndTrace)
                    <> " times"
                )
              -- XXX: We need the shrunkDebugTrace here...
              return (Failure shrunkTrace debugTrace reason)

    testResultToMaybe :: TestResult i o -> Maybe (History i o)
    testResultToMaybe Success = Nothing
    testResultToMaybe (Failure trace _debugTrace _reason) = Just trace

    generate :: Int -> Prng -> (Prng, [(Time, Incoming i o)])
    generate size prng =
      let (prng', initialMessages) =
            Gen.runGen workload.generate prng size
          (prng'', initialMessages', time) =
            generateRandomArrivalTimes
              epoch
              workload.baseLatency
              (map InMessage initialMessages)
              prng'
      in  case workload.finallyGenerate of
            Nothing -> (prng'', addMessageIds initialMessages')
            Just (delay, finallyGen) ->
              let (prng''', finalMessages) = Gen.runGen finallyGen prng'' size
                  (prng'''', finalMessages', _time) =
                    generateRandomArrivalTimes
                      (addTimeMicros delay time)
                      workload.baseLatency
                      (map InMessage finalMessages)
                      prng'''
              in  (prng'''', addMessageIds (initialMessages' <> finalMessages'))

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
