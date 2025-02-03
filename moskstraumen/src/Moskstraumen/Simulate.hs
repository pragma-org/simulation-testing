module Moskstraumen.Simulate (module Moskstraumen.Simulate) where

import Data.List (partition)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import System.Process (readProcess)
import System.Random

import Moskstraumen.Codec
import Moskstraumen.Example.Echo
import qualified Moskstraumen.Generate as Gen
import Moskstraumen.Interface2
import Moskstraumen.LinearTemporalLogic
import Moskstraumen.Message
import Moskstraumen.Node4
import Moskstraumen.NodeId
import Moskstraumen.Prelude
import Moskstraumen.Random
import Moskstraumen.Time
import Moskstraumen.Workload

------------------------------------------------------------------------

data World m = World
  { nodes :: Map NodeId (Interface m)
  , messages :: [Message] -- XXX: should be a heap
  , prng :: Prng
  , trace :: Trace
  }

type Trace = [Message]

data Deployment m = Deployment
  { nodeCount :: Int
  , spawn :: m (Interface m)
  }

type Seed = Int

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

stepWorld :: (Monad m) => World m -> m (Either (World m) ())
stepWorld world = case world.messages of
  [] -> return (Right ())
  (msg : msgs) -> case Map.lookup msg.dest world.nodes of
    Nothing -> error ("stepWorld: unknown destination node: " ++ show msg.dest)
    Just node -> do
      -- XXX: will be used later when we assign arrival times for replies
      let (prng', prng'') = splitPrng world.prng
      msgs' <- node.handle msg
      let (clientReplies, nodeMessages) =
            partition (\msg0 -> "c" `Text.isPrefixOf` unNodeId msg0.dest) msgs'
      return
        $ Left
          World
            { nodes = world.nodes
            , messages = msgs ++ nodeMessages
            , prng = prng''
            , trace = world.trace ++ msg : clientReplies
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
  let nodeNames =
        map
          (NodeId . ("n" <>) . Text.pack . show)
          [1 .. deployment.nodeCount]
  interfaces <-
    replicateM deployment.nodeCount (deployment.spawn)
  return
    World
      { nodes = Map.fromList (zip nodeNames interfaces)
      , messages = initialMessages
      , prng = prng
      , trace = []
      }

------------------------------------------------------------------------

runTest ::
  (Monad m) => Deployment m -> Workload -> [Message] -> Prng -> m Bool
runTest deployment workload initialMessages prng = do
  world <-
    newWorld
      deployment
      initialMessages
      prng
  resultingTrace <- runWorld world
  traverse_ (.close) world.nodes
  return (sat workload.property resultingTrace emptyEnv)

runTests ::
  forall m.
  (Monad m) =>
  Deployment m
  -> Workload
  -> NumberOfTests
  -> Seed
  -> m Bool
runTests deployment workload numberOfTests0 seed =
  loop numberOfTests0 (mkPrng seed)
  where
    loop :: NumberOfTests -> Prng -> m Bool
    loop 0 _prng = return True
    loop n prng = do
      let size = 100 -- XXX: vary over time
      let initMessages =
            [ makeInitMessage (makeNodeId i) (map makeNodeId js)
            | i <- [1 .. deployment.nodeCount]
            , let js = [j | j <- [1 .. deployment.nodeCount], j /= i]
            ]
      let (prng', initialMessages) =
            Gen.runGen (Gen.listOf workload.generateMessage) prng size
      let initialMessages' =
            zipWith
              ( \message index -> message {body = message.body {msgId = Just index}}
              )
              initialMessages
              [0 ..]
      let (prng'', prng''') = splitPrng prng'
      passed <-
        runTest deployment workload (initMessages <> initialMessages') prng''
      if passed
        then loop (n - 1) prng'''
        else return False

------------------------------------------------------------------------

blackboxTestWith :: TestConfig -> FilePath -> Workload -> IO ()
blackboxTestWith testConfig binaryFilePath workload = do
  seed <- case testConfig.replaySeed of
    Nothing -> randomIO
    Just seed -> return seed
  let deployment =
        Deployment
          { nodeCount = testConfig.numberOfNodes
          , spawn = pipeSpawn binaryFilePath
          }
  result <- runTests deployment workload testConfig.numberOfTests seed
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
  seed <- case testConfig.replaySeed of
    Nothing -> randomIO
    Just seed -> return seed
  let deployment =
        Deployment
          { nodeCount = testConfig.numberOfNodes
          , spawn = simulationSpawn node initialState validateMarshal
          }
  result <- runTests deployment workload testConfig.numberOfTests seed
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
                , arrivalTime = Just epoch
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
