module Moskstraumen.Simulate (module Moskstraumen.Simulate) where

import Data.List (partition)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import System.Process (readProcess)

import Moskstraumen.Codec
import Moskstraumen.Example.Echo
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

data World m = World
  { nodes :: Map NodeId (NodeHandle m)
  , messages :: Heap Time Message
  , prng :: Prng
  , trace :: Trace
  }

type Trace = [Message]

data Deployment m = Deployment
  { nodeCount :: Int
  , spawn :: m (NodeHandle m)
  }

type NumberOfTests = Int

data TestConfig = TestConfig
  { numberOfTests :: Int
  , numberOfNodes :: Int
  , replaySeed :: Maybe Int
  }

defaultTestConfig :: TestConfig
defaultTestConfig =
  TestConfig
    { numberOfTests = 100
    , numberOfNodes = 5
    , replaySeed = Nothing
    }

------------------------------------------------------------------------

generateRandomArrivalTimes ::
  Time -> Double -> [Message] -> Prng -> Heap Time Message
generateRandomArrivalTimes now meanMicros = go []
  where
    go acc [] _prng = Heap.fromList acc
    go acc (message : messages) prng =
      let
        (deltaMicros, prng') = exponential meanMicros prng
        arrivalTime = addTimeMicros (round deltaMicros) now
      in
        go ((arrivalTime, message) : acc) messages prng'

stepWorld :: (Monad m) => World m -> m (Either (World m) ())
stepWorld world = case Heap.pop world.messages of
  Nothing -> return (Right ())
  Just ((arrivalTime, message), messages') ->
    case Map.lookup message.dest world.nodes of
      Nothing -> error ("stepWorld: unknown destination node: " ++ show message.dest)
      Just node -> do
        -- XXX: will be used later when we assign arrival times for replies
        let (prng', prng'') = splitPrng world.prng
        msgs' <- node.handle arrivalTime message
        let (clientReplies, nodeMessages) =
              partition (\msg0 -> "c" `Text.isPrefixOf` unNodeId msg0.dest) msgs'
            meanMicros = 20000 -- 20ms
            nodeMessages' = generateRandomArrivalTimes arrivalTime meanMicros nodeMessages prng'
        return
          $ Left
            World
              { nodes = world.nodes
              , messages = messages' <> nodeMessages'
              , prng = prng''
              , trace = world.trace ++ message : clientReplies
              }
{-# SPECIALIZE stepWorld :: World IO -> IO (Either (World IO) ()) #-}

runWorld :: (Monad m) => World m -> m Trace
runWorld world =
  stepWorld world >>= \case
    Right () -> return world.trace
    Left world' -> runWorld world'
{-# SPECIALIZE runWorld :: World IO -> IO Trace #-}

newWorld ::
  (Monad m) => Deployment m -> [Message] -> Prng -> m (World m)
newWorld deployment initialMessages prng = do
  let nodeIds =
        map
          (NodeId . ("n" <>) . Text.pack . show)
          [1 .. deployment.nodeCount]
  nodeHandles <-
    replicateM deployment.nodeCount deployment.spawn
  let (prng', prng'') = splitPrng prng
      meanMicros = 20000 -- 20ms
      initialMessages' = generateRandomArrivalTimes epoch meanMicros initialMessages prng'
  return
    World
      { nodes = Map.fromList (zip nodeIds nodeHandles)
      , messages = initialMessages'
      , prng = prng''
      , trace = []
      }

------------------------------------------------------------------------

data TestResult = Success | Failure Trace
  deriving stock (Eq, Show)

testResultToMaybe :: TestResult -> Maybe Trace
testResultToMaybe Success = Nothing
testResultToMaybe (Failure trace) = Just trace

runTest ::
  (Monad m) =>
  Deployment m
  -> Workload
  -> Prng
  -> [Message]
  -> m TestResult
runTest deployment workload prng initialMessages = do
  world <-
    newWorld
      deployment
      initialMessages
      prng
  resultingTrace <- runWorld world
  traverse_ (.close) world.nodes
  if sat workload.property resultingTrace emptyEnv
    then return Success
    else return (Failure resultingTrace)

runTests ::
  forall m.
  (Monad m) =>
  Deployment m
  -> Workload
  -> NumberOfTests
  -> Prng
  -> m TestResult
runTests deployment workload numberOfTests0 initialPrng =
  loop numberOfTests0 initialPrng
  where
    loop :: NumberOfTests -> Prng -> m TestResult
    loop 0 _prng = return Success
    loop n prng = do
      let size = 100 -- XXX: vary over time
      let initMessages =
            [ makeInitMessage (makeNodeId i) (map makeNodeId js)
            | i <- [1 .. deployment.nodeCount]
            , let js = [j | j <- [1 .. deployment.nodeCount], j /= i]
            ]
      let (prng', initialMessages) =
            Gen.runGen (Gen.listOf workload.generateMessage) prng size
      let initialMessages' :: [Message]
          initialMessages' =
            zipWith
              ( \message index -> message {body = message.body {msgId = Just index}}
              )
              initialMessages
              [0 ..]
      let (prng'', prng''') = splitPrng prng'
      result <-
        runTest deployment workload prng'' (initMessages <> initialMessages')
      case result of
        Success -> loop (n - 1) prng'''
        Failure trace -> do
          initialMessagesAndTrace <-
            shrink
              (fmap testResultToMaybe . runTest deployment workload prng)
              (shrinkList (const []))
              initialMessages'
          let (_failingMessages, failingTrace) = NonEmpty.last initialMessagesAndTrace
          return (Failure failingTrace)

------------------------------------------------------------------------

blackboxTestWith :: TestConfig -> FilePath -> Workload -> IO ()
blackboxTestWith testConfig binaryFilePath workload = do
  (prng, seed) <- newPrng testConfig.replaySeed
  let deployment =
        Deployment
          { nodeCount = testConfig.numberOfNodes
          , spawn = pipeSpawn binaryFilePath seed
          }
  let (prng', _prng'') = splitPrng prng
  result <- runTests deployment workload testConfig.numberOfTests prng'
  putStrLn ("Seed: " <> show seed)
  print result

blackboxTest :: FilePath -> Workload -> IO ()
blackboxTest = blackboxTestWith defaultTestConfig

simulationTestWith ::
  TestConfig
  -> (input -> Node state input output)
  -> state
  -> ValidateMarshal input output
  -> Workload
  -> IO ()
simulationTestWith testConfig node initialState validateMarshal workload = do
  (prng, seed) <- newPrng testConfig.replaySeed
  let (prng', prng'') = splitPrng prng
  let deployment =
        Deployment
          { nodeCount = testConfig.numberOfNodes
          , spawn = simulationSpawn node initialState prng' validateMarshal
          }
  result <- runTests deployment workload testConfig.numberOfTests prng''
  putStrLn ("Seed: " <> show seed)
  print result

simulationTest ::
  (input -> Node state input output)
  -> state
  -> ValidateMarshal input output
  -> Workload
  -> IO ()
simulationTest = simulationTestWith defaultTestConfig

------------------------------------------------------------------------

echoWorkload :: Workload
echoWorkload =
  Workload
    { name = "echo"
    , generateMessage = do
        let makeMessage n =
              Message
                { src = "c1"
                , dest = "n1"
                , body =
                    Payload
                      { kind = "echo"
                      , msgId = Nothing
                      , inReplyTo = Nothing
                      , fields =
                          Map.fromList
                            [
                              ( "echo"
                              , String ("Please echo: " <> fromString (show n))
                              )
                            ]
                      }
                }
        makeMessage <$> Gen.chooseInt (0, 127)
    , property =
        Always
          $ FreezeQuantifier "echo"
          $ Prop (\msg -> msg.body.kind == "echo")
          :==> Eventually
            ( FreezeQuantifier
                "echo_ok"
                ( Prop (\msg -> msg.body.kind == "echo_ok")
                    `And` Var "echo_ok"
                    :. InReplyTo
                    :== Var "echo"
                    :. MsgId
                    `And` Var "echo_ok"
                    :. Project "echo"
                    :== Var "echo"
                    :. Project "echo"
                )
            )
    }

------------------------------------------------------------------------

unit_blackboxTestEcho :: IO ()
unit_blackboxTestEcho = do
  binaryFilePath <-
    filter (/= '\n') <$> readProcess "cabal" ["list-bin", "echo"] ""
  blackboxTest binaryFilePath echoWorkload

unit_simulationTestEcho :: IO ()
unit_simulationTestEcho =
  simulationTest echo () echoValidateMarshal echoWorkload
