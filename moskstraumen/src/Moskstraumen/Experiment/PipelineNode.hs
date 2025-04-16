module Moskstraumen.Experiment.PipelineNode (module Moskstraumen.Experiment.PipelineNode) where

import Control.Applicative
import Control.Concurrent hiding (yield)
import Control.Concurrent.STM
import Control.Exception
import Data.Either
import Data.IORef
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import Debug.Trace
import System.IO.Unsafe
import System.Timeout

import Moskstraumen.FreeMonad
import Moskstraumen.NodeId
import Moskstraumen.Prelude

------------------------------------------------------------------------

newtype Node s i o = Node (i -> NodeBody s i o ())

newtype NodeBody s i o a = NodeBody {unNodeBody :: Free (NodeBodyF s i o) a}
  deriving newtype (Functor, Applicative, Monad)

data NodeBodyF s i o x
  = Yield o (() -> x)
  | Get (s -> x)
  | Put s ~x
  | Send NodeId i ~x
  | AsyncIO (IO ()) (() -> x) (() -> x)
  deriving (Functor)

yield :: o -> NodeBody s i o ()
yield o = NodeBody (generic' (Yield o))

asyncIO :: IO () -> (() -> NodeBody s i o ()) -> NodeBody s i o ()
asyncIO io k = NodeBody (generic' (AsyncIO io (unNodeBody . k)))

data Effect = DoIO StageId (IO ()) CallbackId

instance Show Effect where
  show (DoIO stageId _io callbackId) =
    "DoIO "
      <> Text.unpack (unStageId stageId)
      <> " <io> "
      <> show callbackId

type CallbackId = Word

data NodeState s o = NodeState
  { localState :: s
  , callbacks :: Map CallbackId (NodeState s o)
  , outputs :: [o]
  , effects :: [Effect]
  , nextCallbackId :: Word
  }

instance (Show s, Show o) => Show (NodeState s o) where
  show ns =
    unlines
      [ "NodeState"
      , "  { localState     = " <> show ns.localState
      , "  , callbacks      = " <> show ns.callbacks
      , "  , outputs        = " <> show ns.outputs
      , "  , effects        = " <> show ns.effects
      , "  , nextCallbackId = " <> show ns.nextCallbackId
      , "  }"
      ]

initialNodeState :: s -> NodeState s o
initialNodeState initialState =
  NodeState
    { localState = initialState
    , callbacks = Map.empty
    , outputs = []
    , effects = []
    , nextCallbackId = 0
    }

data Callback = Callback CallbackId
  deriving stock (Show)

runNode ::
  forall s i o.
  (Show s, Show o) =>
  StageId
  -> Node s i o
  -> NodeState s o
  -> Either Callback i
  -> NodeState s o
runNode _stageId (Node node) ns0 (Left (Callback callbackId)) =
  case Map.lookup callbackId ns0.callbacks of
    Nothing ->
      error
        ( "runNode: got unexpected callback: " <> show (callbackId, ns0.callbacks)
        )
    Just ns ->
      -- trace
      --  "[runNode] callback"
      (ns {callbacks = Map.delete callbackId ns0.callbacks} :: NodeState s o)
runNode stageId (Node node) ns0 (Right i) = case node i of
  NodeBody body -> iterM go leaf body ns0 {outputs = [], effects = []}
    where
      leaf :: () -> NodeState s o -> NodeState s o
      leaf () ns = ns

      go :: Alg (NodeBodyF s i o) (NodeState s o -> NodeState s o)
      go (Yield o k) ns = k () ns {outputs = o : outputs ns}
      go (Get k) ns = k ns.localState ns
      go (Put s' k) ns = k ns {localState = s'}
      go (Send nodeId i ih) _ = undefined
      go (AsyncIO io k ih) ns =
        let callbackId = ns.nextCallbackId
        in  ih
              ()
              ns
                { callbacks = Map.insert callbackId (k () ns) ns.callbacks
                , effects = DoIO stageId io callbackId : ns.effects
                , nextCallbackId = callbackId + 1
                }

------------------------------------------------------------------------

newtype StageId = StageId {unStageId :: Text}
  deriving newtype (Eq, Ord, IsString)

data Deployment i o = Deployment
  { transformer :: Queue i -> Queue Effect -> IO (Queue o, StageHandles)
  }

type StageHandles = Map StageId StageHandle

data StageHandle = StageHandle
  { pid :: ThreadId
  , stageStateVar :: TMVar StageState
  , source :: Some TBQueue
  , -- , control :: Queue Command
    -- , observe :: Queue Response
    -- , errors :: Queue SomeException
    callbacks :: Queue Callback
  }

data Some f = forall a. Some (f a)

data StageState
  = Paused
  | Running
  | Stopped
  | Step
  deriving stock (Eq, Show)

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
    { transformer = \qi _qe -> return (qi, Map.empty)
    }

composeDeployment :: Deployment i j -> Deployment j k -> Deployment i k
composeDeployment d1 d2 =
  Deployment
    { transformer = \qi qe -> do
        (qj, m) <- d1.transformer qi qe
        (qk, m') <- d2.transformer qj qe
        return (qk, m <> m')
    }

------------------------------------------------------------------------

deployFun :: StageId -> (i -> o) -> Deployment i o
deployFun stageId f =
  Deployment
    { transformer = \qi qe -> do
        qo <- newQueue
        qc <- newQueue
        stageStateVar <- newEmptyTMVarIO
        pid <- forkIO
          $ forever
          $ atomically
          $ do
            stageState <- takeTMVar stageStateVar
            case stageState of
              Running -> do
                i <- readTBQueue qi
                let o = f i
                writeTBQueue qo o
                writeTMVar stageStateVar Running
              Step -> do
                i <- readTBQueue qi
                let o = f i
                writeTBQueue qo o
        return
          (qo, Map.singleton stageId (StageHandle pid stageStateVar (Some qi) qc))
    }

deployNode ::
  (Show s, Show i, Show o) => StageId -> Node s i o -> s -> Deployment i o
deployNode stageId node initialState =
  Deployment
    { transformer = \qi qe -> do
        qo <- newQueue
        qc <- newQueue
        stageStateVar <- newEmptyTMVarIO
        let loop ns = do
              ns' <- atomically $ do
                stageState <- takeTMVar stageStateVar
                -- traceM (show stageState)
                eci <- (Left <$> readTBQueue qc) <|> (Right <$> readTBQueue qi)
                -- traceM (show eci)
                let ns' = runNode stageId node ns eci
                -- traceM ("[deployNode] " <> show ns')
                forM_ ns'.effects $ \e -> do
                  -- traceM ("[deployNode] writing effect: " <> show e)
                  writeTBQueue qe e
                -- len <- lengthTBQueue qe
                -- traceM $ "[deployNode] effects queue length: " <> show len
                forM_ ns'.outputs $ \o -> do
                  -- traceM ("[deployNode] writing output: " <> show o)
                  writeTBQueue qo o
                return ns'
              loop ns'
        pid <-
          forkIO
            $ loop
              ( NodeState
                  { localState = initialState
                  , callbacks = Map.empty
                  , outputs = []
                  , effects = []
                  , nextCallbackId = 0
                  }
              )
        return
          (qo, Map.singleton stageId (StageHandle pid stageStateVar (Some qi) qc))
    }

------------------------------------------------------------------------

step :: StageId -> StageHandles -> IO ()
step stageId stageHandles = case Map.lookup stageId stageHandles of
  Nothing -> error "step: no such stage id"
  Just stageHandle -> atomically (putTMVar stageHandle.stageStateVar Step)

inputLen :: StageId -> StageHandles -> IO Int
inputLen stageId stageHandles = case Map.lookup stageId stageHandles of
  Nothing -> error "inputLen: no such stage id"
  Just stageHandle -> case stageHandle.source of
    Some q -> atomically (fromIntegral <$> lengthTBQueue q)

shutdown :: StageHandles -> IO ()
shutdown = traverse_ (\stageHandle -> killThread stageHandle.pid)

writeCallback :: Callback -> StageId -> StageHandles -> IO ()
writeCallback callback stageId stageHandles = case Map.lookup stageId stageHandles of
  Nothing -> error "writeCallback: no such stage id"
  Just stageHandle -> do
    -- putStrLn
    --   $ "[writeCallback]: writing callback to: "
    --   <> Text.unpack (unStageId stageId)
    atomically (writeTBQueue stageHandle.callbacks callback)

------------------------------------------------------------------------

testDeployment :: [i] -> Deployment i o -> IO [o]
testDeployment inputs deployment = do
  qi <- newQueue
  qe <- newQueue
  qc <- newQueue -- XXX: unused
  mapM_ (atomically . writeTBQueue qi) inputs
  (qo, stageHandles) <- deployment.transformer qi qe
  effectsPid <- forkIO $ forever $ do
    -- putStrLn "[effects] waiting for effects"
    me <- timeout 1000000 $ atomically (readTBQueue qe)
    case me of
      Nothing -> do
        -- putStrLn "[effects] timeout"
        -- len <- atomically (lengthTBQueue qe)
        -- putStrLn $ "[effects] effects queue length: " <> show len
        return ()
      Just (DoIO stageId io callbackId) -> do
        -- traceM "[effects] performing effect:"
        _ <- io
        writeCallback (Callback callbackId) stageId stageHandles
  _effectsStateVar <- newTMVarIO Running

  traverse_
    ( \stageHandle -> atomically (writeTMVar stageHandle.stageStateVar Running)
    )
    stageHandles
  -- XXX: if multiple yields are used then we can't just read length input many
  -- times... Read until EndOfStream token?
  replicateM (length inputs) (atomically (readTBQueue qo))
    `finally` shutdown
      ( stageHandles
          <> Map.singleton
            "effects"
            (StageHandle effectsPid _effectsStateVar (Some qe) qc)
      )

testDeployment' :: (Show o) => [i] -> Deployment i o -> IO StageHandles
testDeployment' inputs deployment = do
  qi <- newQueue
  qe <- newQueue
  qc <- newQueue -- XXX: unused
  mapM_ (atomically . writeTBQueue qi) inputs
  (qo, stageHandles) <- deployment.transformer qi qe
  effectsStateVar <- newEmptyTMVarIO
  effectsPid <- forkIO $ forever $ do
    state <- atomically (takeTMVar effectsStateVar)
    e <- atomically (readTBQueue qe)
    case e of
      DoIO stageId io callbackId -> do
        -- traceM ("[effects] DoIO: " <> Text.unpack (unStageId stageId))
        _ <- io
        writeCallback (Callback callbackId) stageId stageHandles
    case state of
      Step -> return ()
      Running -> atomically (writeTMVar effectsStateVar Running)

  sinkStateVar <- newEmptyTMVarIO
  pid <- forkIO $ forever $ do
    -- replicateM_ (length inputs) $ do
    state <- atomically (takeTMVar sinkStateVar)
    o <- atomically (readTBQueue qo)
    putStr "[sink] "
    print o
    case state of
      Step -> return ()
      Running -> atomically (writeTMVar sinkStateVar Running)
  return
    ( Map.singleton "sink" (StageHandle pid sinkStateVar (Some qi) qc)
        <> Map.singleton
          "effects"
          (StageHandle effectsPid effectsStateVar (Some qe) qc)
        <> stageHandles
    )

------------------------------------------------------------------------

echoLog :: Node () Int Int
echoLog = Node $ \i -> asyncIO (print (show i)) (\_ -> yield i >> yield i)

t :: IO ()
t = do
  h <- testDeployment' [1, 2, 3] (deployNode "echoLog" echoLog ())
  -- print =<< inputLen "echoLog" h
  step "echoLog" h
  step "echoLog" h
  step "effects" h
  step "sink" h
  step "sink" h
  step "echoLog" h
  step "echoLog" h
  step "effects" h
  step "sink" h
  step "sink" h
  step "echoLog" h
  step "echoLog" h
  step "effects" h
  step "sink" h
  step "sink" h
  threadDelay 100000
  shutdown h
