module Moskstraumen.Simulate (module Moskstraumen.Simulate) where

import Data.List (partition)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import System.Random

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

------------------------------------------------------------------------

data Deployment m = Deployment
  { nodeCount :: Int
  , spawn :: m (Interface m)
  }

type Seed = Int

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

test :: (Monad m) => Deployment m -> [Message] -> Prng -> m Bool
test deployment initialMessages prng = do
  world <-
    newWorld
      deployment
      initialMessages
      prng
  resultingTrace <- runWorld world
  traverse_ (.close) world.nodes
  return (sat (liveness "echo") resultingTrace emptyEnv)
  where
    liveness :: Text -> Form Message
    liveness req =
      Always
        $ FreezeQuantifier req
        $ Prop (\msg -> msg.body.kind == MessageKind req)
        :==> Eventually
          ( FreezeQuantifier
              resp
              ( Prop (\msg -> msg.body.kind == MessageKind resp)
                  `And` Var resp
                  :. InReplyTo
                  :== Var req
                  :. MsgId
                  `And` Var resp
                  :. Project "echo"
                  :== Var req
                  :. Project "echo"
              )
          )
      where
        resp = req <> "_ok"

data Result = Success | Failure
  deriving (Show)

t' :: (Monad m) => Deployment m -> [Message] -> Prng -> Int -> m Result
t' deployment initialMessages prng = go prng
  where
    go _prng 0 = return Success
    go prng n = do
      let (prng', prng'') = splitPrng prng
      passed <- test deployment initialMessages prng'
      if passed
        then go prng'' (n - 1)
        else return Failure

t :: IO ()
t = do
  seed <- randomIO

  let prng = mkPrng seed

  let initialMessages =
        [ Message
            { src = "c1"
            , dest = "n1"
            , arrivalTime = Just epoch
            , body =
                Payload
                  { kind = "echo"
                  , msgId = Just 0
                  , inReplyTo = Nothing
                  , fields = Map.fromList [("echo", String "hi")]
                  }
            }
        ]
  result <- t' echoPipeDeployment initialMessages prng numberOfTests
  print result
  where
    numberOfTests = 100

echoPipeDeployment :: Deployment IO
echoPipeDeployment =
  Deployment
    { nodeCount = 1
    , spawn =
        pipeSpawn
          "/home/stevan/src/simulation-testing/moskstraumen/dist-newstyle/build/x86_64-linux/ghc-9.10.1/moskstraumen-0.0.0/x/echo/build/echo/echo"
    }

------------------------------------------------------------------------

type NumberOfTests = Int

simulationTest ::
  forall m.
  (Monad m) =>
  Workload
  -> Deployment m
  -> NumberOfTests
  -> Seed
  -> m Bool
simulationTest workload deployment numberOfTests seed =
  loop numberOfTests (mkPrng seed)
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
        test2 workload deployment (initMessages <> initialMessages') prng''
      if passed
        then loop (n - 1) prng'''
        else return False

test2 ::
  (Monad m) => Workload -> Deployment m -> [Message] -> Prng -> m Bool
test2 workload deployment initialMessages prng = do
  world <-
    newWorld
      deployment
      initialMessages
      prng
  resultingTrace <- runWorld world
  traverse_ (.close) world.nodes
  return (sat workload.property resultingTrace emptyEnv)

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

echoPureDeployment :: IO (Deployment IO)
echoPureDeployment =
  return
    Deployment
      { nodeCount = 1
      , spawn = simulationSpawn echo () echoValidateMarshal
      }

unit_echoWithSeed :: Seed -> IO ()
unit_echoWithSeed seed = do
  deployment <- echoPureDeployment
  let numberOfTests = 1
  result <- simulationTest echoWorkload deployment numberOfTests seed
  print seed
  print result

unit_echo :: IO ()
unit_echo = do
  seed <- randomIO
  unit_echoWithSeed seed
