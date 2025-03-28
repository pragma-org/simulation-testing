module Moskstraumen.Simulate (module Moskstraumen.Simulate) where

import Control.Exception
import Data.List (partition)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import qualified Data.Text.IO as Text
import System.Timeout
import Text.Printf

import Moskstraumen.Codec
import qualified Moskstraumen.Generate as Gen
import Moskstraumen.Heap (Heap)
import qualified Moskstraumen.Heap as Heap
import Moskstraumen.LinearTemporalLogic
import Moskstraumen.Message
import Moskstraumen.Node4
import Moskstraumen.NodeHandle
import Moskstraumen.NodeId
import Moskstraumen.Prelude
import Moskstraumen.Random
import Moskstraumen.Shrink
import Moskstraumen.Time
import Moskstraumen.Workload

------------------------------------------------------------------------

-- start snippet World
data World = World
  { nodes :: Map NodeId NodeHandle
  , messages :: Heap Time Message
  , prng :: Prng
  , trace :: Trace
  }

-- end snippet

-- start snippet Trace
type Trace = [(Time, Message)]

-- end snippet

-- start snippet Deployment
data Deployment = Deployment
  { numberOfNodes :: Int
  , spawn :: IO NodeHandle
  }

-- end snippet

type NumberOfTests = Int

-- start snippet TestConfig
data TestConfig = TestConfig
  { numberOfTests :: Int
  , numberOfNodes :: Int
  , replaySeed :: Maybe Int
  , disableShrinking :: Bool
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
    }

-- end snippet

------------------------------------------------------------------------

generateRandomArrivalTimes ::
  Time -> Double -> [Message] -> Prng -> (Prng, Heap Time Message)
generateRandomArrivalTimes now meanMicros = go 0 []
  where
    go _i acc [] prng = (prng, Heap.fromList acc)
    go i acc (message : messages) prng =
      let
        (deltaMicros, prng') = exponential meanMicros prng
        -- XXX: deltaMicros shouldn't be hardcoded.
        deltaMicros' = i
        arrivalTime = addTimeMicros (round deltaMicros') now
      in
        go (i + 1) ((arrivalTime, message) : acc) messages prng'

-- start snippet stepWorld
stepWorld :: World -> IO (Either World ())
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
              "------------------------------------------------------------------------"
            putStrLn "node.handle failed:"
            error (displayException (err :: SomeException))
          Just (Right responses) -> do
            let (clientResponses, nodeMessages) =
                  partition (isClientNodeId . dest) responses
                meanMicros = 20000 -- 20ms
                (prng', nodeMessages') =
                  generateRandomArrivalTimes
                    arrivalTime
                    meanMicros
                    nodeMessages
                    world.prng
            return
              $ Left
                World
                  { nodes = world.nodes
                  , messages = messages' <> nodeMessages'
                  , prng = prng'
                  , -- XXX: the arrival time for client responses is arbitrary
                    trace =
                      world.trace ++ (arrivalTime, message)
                        : map
                          ( \clientResponse -> (addTimeMicros (round meanMicros) arrivalTime, clientResponse)
                          )
                          clientResponses
                  }

-- end snippet

-- start snippet runWorld
runWorld :: World -> IO Trace
runWorld world =
  stepWorld world >>= \case
    Right () -> return world.trace
    Left world' -> runWorld world'

-- end snippet

-- start snippet newWorld
newWorld :: Deployment -> Heap Time Message -> Prng -> IO World
newWorld deployment initialMessages prng = do
  let nodeIds =
        map
          (NodeId . ("n" <>) . Text.pack . show)
          [1 .. deployment.numberOfNodes]
  nodeHandles <- replicateM deployment.numberOfNodes deployment.spawn
  return
    World
      { nodes = Map.fromList (zip nodeIds nodeHandles)
      , messages = initialMessages
      , prng = prng
      , trace = []
      }

-- end snippet

------------------------------------------------------------------------

-- start snippet TestResult
data TestResult = Success | Failure Trace Reason
  -- end snippet
  deriving stock (Eq, Show)

type Reason = String

testResultToMaybe :: TestResult -> Maybe Trace
testResultToMaybe Success = Nothing
testResultToMaybe (Failure trace _reason) = Just trace

handleResult ::
  Maybe (IO Text, Message -> Text) -> TestResult -> Seed -> IO Bool
handleResult mPrettyMessage (Failure trace reason) seed = do
  preamble <- maybe (return "") fst mPrettyMessage
  Text.putStrLn preamble
  putStrLn "Trace: "
  mapM_
    ( Text.putStrLn
        . ( \(index, (_time, message)) ->
              Text.pack (printf "%3d" index)
                <> ". "
                <> maybe textShow (\f m -> f m) (fmap snd mPrettyMessage) message
          )
    )
    (zip [1 :: Int ..] trace)
  putStrLn ""
  putStrLn ("Seed: " <> show seed)
  putStrLn ""
  putStrLn ("Failure: " <> reason)
  return False
handleResult _mPrettyMessage Success _seed = do
  putStrLn "Success!"
  return True

-- start snippet runTest
runTest ::
  Deployment -> Workload -> Prng -> Heap Time Message -> IO TestResult
runTest deployment workload prng initialMessages = do
  world <-
    newWorld
      deployment
      initialMessages
      prng
  resultingTrace <-
    runWorld world `finally` traverse_ (.close) world.nodes
  let propertyResult = case workload.property of
        -- XXX: we are throwing away arrival times here, we should use them in the LTL checker!
        LTL formula ->
          if sat formula (map snd resultingTrace) emptyEnv
            then Pass
            else Fail "LTL formula failed"
        TracePredicate predicate -> predicate (map snd resultingTrace)
  case propertyResult of
    Pass -> return Success
    Fail reason -> do
      return (Failure resultingTrace reason)

-- end snippet

-- start snippet runTests
runTests ::
  TestConfig
  -> Deployment
  -> Workload
  -> Prng
  -> IO TestResult
runTests testConfig deployment workload initialPrng =
  loop testConfig.numberOfTests initialPrng
  where
    loop :: NumberOfTests -> Prng -> IO TestResult
    loop 0 _prng = return Success
    loop n prng = do
      let size = 30 -- XXX: vary size over time...
      let (prng', initialMessages) = generate size prng
      let meanMicros = 20000 -- 20ms  -- XXX: make parameter of workload
      let (prng'', initialMessages') =
            generateRandomArrivalTimes epoch meanMicros initialMessages prng'
      let (prng''', prng'''') = splitPrng prng''
      let neighbours i = ["c1"] -- XXX: [makeNodeId j | j <- [1 .. deployment.numberOfNodes], j /= i]
      let initMessages =
            Heap.fromList
              [ (epoch, makeInitMessage (makeNodeId i) (neighbours i))
              | i <- [1 .. deployment.numberOfNodes]
              ]
      result <-
        runTest deployment workload prng''' (initMessages <> initialMessages')
      case result of
        Success -> loop (n - 1) prng''''
        Failure unShrunkTrace reason -> do
          if testConfig.disableShrinking
            then return (Failure unShrunkTrace reason)
            else do
              putStrLn "Shrinking..."
              initialMessagesAndTrace <-
                shrink
                  (fmap testResultToMaybe . runTest deployment workload prng)
                  (map Heap.fromList . shrinkList (const []) . Heap.toList)
                  (initMessages <> initialMessages') -- XXX: avoid shrinking initMessages?
              let (_shrunkMessages, shrunkTrace) = NonEmpty.last initialMessagesAndTrace
              putStrLn
                ( "Shrunk: "
                    <> show (NonEmpty.length initialMessagesAndTrace)
                )
              return (Failure shrunkTrace reason)

    generate :: Int -> Prng -> (Prng, [Message])
    generate size prng =
      let (prng', initialMessages) =
            Gen.runGen workload.generate prng size

          messages :: [Message]
          messages =
            zipWith
              ( \message index -> message {body = message.body {msgId = Just index}}
              )
              initialMessages
              [0 ..]
      in  (prng', messages)

-- end snippet

------------------------------------------------------------------------

-- start snippet blackboxTest
blackboxTestWith ::
  TestConfig -> FilePath -> (Seed -> [String]) -> Workload -> IO Bool
blackboxTestWith testConfig binaryFilePath args workload = do
  (prng, seed) <- newPrng testConfig.replaySeed
  let deployment =
        Deployment
          { numberOfNodes = testConfig.numberOfNodes
          , spawn = pipeNodeHandle binaryFilePath (args seed)
          }
  let (prng', _prng'') = splitPrng prng
  result <- runTests testConfig deployment workload prng'
  handleResult workload.prettyFailure result seed

blackboxTest :: FilePath -> Workload -> IO Bool
blackboxTest binary = blackboxTestWith defaultTestConfig binary (const [])

-- end snippet

simulationTestWith ::
  TestConfig
  -> (input -> Node state input output)
  -> state
  -> ValidateMarshal input output
  -> Workload
  -> IO Bool
simulationTestWith testConfig node initialState validateMarshal workload = do
  (prng, seed) <- newPrng testConfig.replaySeed
  let (prng', prng'') = splitPrng prng
  let deployment =
        Deployment
          { numberOfNodes = testConfig.numberOfNodes
          , spawn = simulationSpawn node initialState prng' validateMarshal
          }
  result <- runTests testConfig deployment workload prng''
  handleResult workload.prettyFailure result seed

simulationTest ::
  (input -> Node state input output)
  -> state
  -> ValidateMarshal input output
  -> Workload
  -> IO Bool
simulationTest = simulationTestWith defaultTestConfig
