module Moskstraumen.Simulate (module Moskstraumen.Simulate) where

import Data.List (partition)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import System.Random

import Moskstraumen.Example.Echo
import Moskstraumen.Interface
import Moskstraumen.Message
import Moskstraumen.Node
import Moskstraumen.NodeId
import Moskstraumen.Prelude

------------------------------------------------------------------------

data World m = World
  { nodes :: Map NodeId (Interface m)
  , messages :: [Message] -- XXX: should be a heap
  , prng :: StdGen
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
      let (prng', prng'') = split world.prng
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
  (Monad m) => Deployment m -> [Message] -> StdGen -> m (World m)
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

test :: (Monad m) => Deployment m -> [Message] -> StdGen -> m Bool
test deployment initialMessages prng = do
  world <-
    newWorld
      deployment
      initialMessages
      prng
  traverse_ (.close) world.nodes
  resultingTrace <- runWorld world
  -- XXX: assert something about trace, e.g.:

  -- if sat
  --   ( always
  --       ( Prop (\e -> e.from == Client && e.content == Write)
  --           ==> eventually
  --             ( Prop (\e -> e.to == Client && (e.content == Ack || e.content == Abort))
  --             )
  --       )
  --   )
  --   trace
  --   then return True
  --   else do
  --     putStrLn $ "Failure, seed: " ++ show seed
  --     mapM_ (putStrLn . prettyEnvelope) (runSim sim)
  --     return False
  return True

data Result = Success | Failure
  deriving (Show)

t' :: (Monad m) => Deployment m -> [Message] -> Seed -> Int -> m Result
t' deployment initialMessages seed = go (mkStdGen seed)
  where
    go _prng 0 = return Success
    go prng n = do
      let (prng', prng'') = split prng
      passed <- test deployment initialMessages prng'
      if passed
        then go prng'' (n - 1)
        else return Failure

t :: IO ()
t = do
  seed <- randomIO

  let initialMessages =
        [ Message
            { src = "c1"
            , dest = "n1"
            , body =
                Payload
                  { kind = "echo"
                  , msgId = Just 0
                  , inReplyTo = Nothing
                  , fields = Map.fromList [("echo", String "hi")]
                  }
            }
        ]
  result <- t' echoPipeDeployment initialMessages seed numberOfTests
  print result
  where
    numberOfTests = 100

echoPipeDeployment :: Deployment IO
echoPipeDeployment =
  Deployment
    { nodeCount = 1
    , spawn =
        pipeSpawn
          "/home/stevan/src/moskstraumen/dist-newstyle/build/x86_64-linux/ghc-9.10.1/moskstraumen-0.0.0/x/echo/build/echo/echo"
    }

------------------------------------------------------------------------

echoPureDeployment :: Deployment IO
echoPureDeployment =
  Deployment
    { nodeCount = 1
    , spawn = pureSpawn echoValidate echo ()
    }

s :: Seed -> IO ()
s seed = do
  let initialMessages =
        [ Message
            { src = "c1"
            , dest = "n1"
            , body =
                Payload
                  { kind = "echo"
                  , msgId = Just 0
                  , inReplyTo = Nothing
                  , fields = Map.fromList [("echo", String "hi")]
                  }
            }
        ]
  result <- t' echoPureDeployment initialMessages seed numberOfTests
  print result
  where
    numberOfTests = 100
