module Moskstraumen.Node6 (module Moskstraumen.Node6) where

import Control.Concurrent
import Control.Concurrent.STM
import Control.Exception
import Data.IORef
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import System.IO.Unsafe

import Moskstraumen.FreeMonad
import Moskstraumen.NodeId
import Moskstraumen.Prelude

------------------------------------------------------------------------

newtype Node s i o = Node (i -> NodeBody s i o)

newtype NodeBody s i o = NodeBody (Free (NodeBodyF s i o) o)

data NodeBodyF s i o x
  = Reply o ~x
  | Get (s -> x)
  | Put s ~x
  | Send NodeId i ~x

newtype StageId = StageId Text
  deriving newtype (Eq, Ord, IsString)

data Deployment i o = Deployment
  { transformer :: Queue i -> IO (Queue o, StageHandles)
  }

type StageHandles = Map StageId StageHandle

data StageHandle = StageHandle
  { pid :: ThreadId
  , stageStateVar :: TVar StageState
  , inbox :: Some TBQueue
  -- , control :: Queue Command
  -- , observe :: Queue Response
  -- , errors :: Queue SomeException
  -- , effects :: Queue (Message Value)
  }

data Some f = forall a. Some (f a)

data StageState
  = Paused
  | Running
  | Stopped
  | Step

------------------------------------------------------------------------

type Queue a = TBQueue a

newQueue :: IO (Queue a)
newQueue = newTBQueueIO 128

readQueue :: Queue a -> IO a
readQueue = atomically . readTBQueue

writeQueue :: Queue a -> a -> IO ()
writeQueue q x = atomically (writeTBQueue q x)

------------------------------------------------------------------------

idDeployment :: Deployment i i
idDeployment =
  Deployment
    { transformer = \qi -> return (qi, Map.empty)
    }

composeDeployment :: Deployment i j -> Deployment j k -> Deployment i k
composeDeployment d1 d2 =
  Deployment
    { transformer = \qi ->
        d1.transformer qi >>= \(qj, m) -> d2.transformer qj >>= \(qk, m') -> return (qk, m <> m')
    }

------------------------------------------------------------------------

deployFun :: StageId -> (i -> o) -> Deployment i o
deployFun stageId f =
  Deployment
    { transformer = \qi -> do
        qo <- newQueue
        stageStateVar <- newTVarIO Paused
        pid <- forkIO
          $ forever
          $ atomically
          $ do
            stageState <- readTVar stageStateVar
            case stageState of
              Paused -> retry
              Running -> do
                i <- readTBQueue qi
                let o = f i
                writeTBQueue qo o
              Step -> do
                i <- readTBQueue qi
                let o = f i
                writeTBQueue qo o
                writeTVar stageStateVar Paused
        return
          (qo, Map.singleton stageId (StageHandle pid stageStateVar (Some qi)))
    }

deployNode :: StageId -> Node s i o -> s -> IO (Deployment i o)
deployNode stageId node initialState = do
  source <- newTBQueueIO 128
  sink <- newTBQueueIO 128
  pid <- forkIO $ forever $ do
    undefined

  undefined

------------------------------------------------------------------------

step :: StageId -> StageHandles -> IO ()
step stageId stageHandles = case Map.lookup stageId stageHandles of
  Nothing -> error "step: no such stage id"
  Just stageHandle -> atomically (writeTVar stageHandle.stageStateVar Step)

inputLen :: StageId -> StageHandles -> IO Int
inputLen stageId stageHandles = case Map.lookup stageId stageHandles of
  Nothing -> error "inputLen: no such stage id"
  Just stageHandle -> case stageHandle.inbox of
    Some q -> atomically (fromIntegral <$> lengthTBQueue q)

shutdown :: StageHandles -> IO ()
shutdown = traverse_ (\stageHandle -> killThread stageHandle.pid)

------------------------------------------------------------------------

testDeployment :: [i] -> Deployment i o -> IO [o]
testDeployment inputs deployment = do
  qi <- newQueue
  mapM_ (atomically . writeTBQueue qi) inputs
  (qo, stageHandles) <- deployment.transformer qi
  traverse_
    ( \stageHandle -> atomically (writeTVar stageHandle.stageStateVar Running)
    )
    stageHandles
  replicateM (length inputs) (atomically (readTBQueue qo))
    `finally` shutdown stageHandles

testDeployment' :: (Show o) => [i] -> Deployment i o -> IO StageHandles
testDeployment' inputs deployment = do
  qi <- newQueue
  mapM_ (atomically . writeTBQueue qi) inputs
  (qo, stageHandles) <- deployment.transformer qi
  pid <- forkIO $ replicateM_ (length inputs) $ do
    o <- atomically (readTBQueue qo)
    print o
  sinkStateVar <- newTVarIO Running
  return
    ( Map.singleton "sink" (StageHandle pid sinkStateVar (Some qi))
        <> stageHandles
    )
