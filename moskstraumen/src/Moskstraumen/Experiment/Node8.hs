{-# LANGUAGE FlexibleContexts #-}

module Moskstraumen.Experiment.Node8 (module Moskstraumen.Experiment.Node8) where

-- Fork of Node5 where we add RPC.

import Control.Applicative
import Control.Concurrent
import Control.Concurrent.STM
import Control.Exception (SomeException, assert, catch, finally)
import Data.Aeson
import qualified Data.Aeson as Json
import qualified Data.Aeson.Types as Json
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BS8
import qualified Data.ByteString.Lazy.Char8 as LBS8
import Data.IORef
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.Text.IO as Text
import Debug.Trace
import GHC.Generics (Rep)
import System.IO
import System.Process
import qualified System.Timeout as Timeout
import Text.Read (readEither)

import Moskstraumen.FreeMonad
import Moskstraumen.Message3
import qualified Moskstraumen.Message3 as Message
import Moskstraumen.NodeId
import Moskstraumen.Prelude
import Moskstraumen.Random
import Moskstraumen.Simulate (blackboxTest)
import Moskstraumen.Time
import Moskstraumen.TimerWheel2
import qualified Moskstraumen.TimerWheel2 as TimerWheel
import Moskstraumen.VarId

------------------------------------------------------------------------

-- start snippet Node

type Node s i o = i -> NodeBody s i o ()

newtype NodeBody s i o a = NodeBody {unNodeBody :: Free (NodeF s i o) a}

-- end snippet

-- start snippet NodeF
data NodeF s i o x
  = Reply o (() -> x)
  | Get (NodeState s -> x)
  | Put (NodeState s) (() -> x)
  | Send NodeId i (() -> x)
  | -- NOTE: It can't be `After Int x (() -> x)`, because then the effects of
    -- the continuation (second `x`) will be part of the suspension (first `x`),
    -- I think because of how `iterM` works... Same with Rpc.
    After Int (NodeBody s i o ()) (() -> x)
  | Rpc
      NodeId
      i
      (RpcError -> NodeBody s i o ())
      (o -> NodeBody s i o ())
      (() -> x)
  | GetTime (Time -> x)
  | Log Text (() -> x)
  | -- end snippet
    -- Fail String
    NewVar (VarId -> x)
  | forall v. DeliverVar VarId v x
  | forall v. AwaitVar VarId (v -> x)
  | At Time x (() -> x)

-- start snippet NodeState
data NodeState s = NodeState
  { localState :: s
  , self :: NodeId
  , nodeTime :: Time
  , neighbours :: [NodeId]
  , sender :: NodeId
  , inReplyTo :: MessageId
  }

-- end snippet

instance Functor (NodeF s i o) where
  fmap f (Reply o k) = Reply o (f . k)
  fmap f (Get k) = Get (f . k)
  fmap f (Put s' k) = Put s' (f . k)
  fmap f (Send nodeId i k) = Send nodeId i (f . k)
  fmap f (Rpc nodeId i failure success k) = Rpc nodeId i failure success (f . k)
  fmap f (After micros task k) = After micros task (f . k)
  fmap f (Log text k) = Log text (f . k)
  fmap f (GetTime k) = GetTime (f . k)
  -- fmap _f (Fail string) = Fail string
  fmap f (NewVar k) = NewVar (f . k)
  fmap f (DeliverVar varId var x) = DeliverVar varId var (f x)
  fmap f (AwaitVar varId k) = AwaitVar varId (f . k)

instance Functor (NodeBody s i o) where
  fmap f (NodeBody m) = NodeBody (fmap f m)

instance Applicative (NodeBody s i o) where
  pure = NodeBody . Pure
  NodeBody mf <*> NodeBody mx = NodeBody (mf <*> mx)

-- instance MonadFail (NodeBody s i o) where
--   fail = NodeBody . Free . Fail

-- instance Alternative (NodeBody s i o) where
--   empty = fail "empty"
--   NodeBody (Free (Fail _)) <|> n = n
--   m <|> _n = m

-- instance MonadPlus (NodeBody s i o) where
--   mzero = empty
--   mplus = (<|>)
--
instance Monad (NodeBody s i o) where
  return = pure
  NodeBody m >>= k = NodeBody (m >>= unNodeBody . k)

------------------------------------------------------------------------

generic ::
  ( (x -> Free f x)
    -> NodeF state input output (Free (NodeF state input output) a)
  )
  -> NodeBody state input output a
generic op = NodeBody (Free (op Pure))

generic_ ::
  ( Free f ()
    -> NodeF state input output (Free (NodeF state input output) a)
  )
  -> NodeBody state input output a
generic_ op = NodeBody (Free (op (Pure ())))

getState :: NodeBody s i o s
getState = localState <$> generic Get

putState :: s -> NodeBody s i o ()
putState s' = do
  ns <- generic Get
  generic (Put ns {localState = s'})

modifyState :: (s -> s) -> NodeBody s i o ()
modifyState f = do
  s <- getState
  putState (f s)

setSelf :: NodeId -> NodeBody s i o ()
setSelf self = do
  ns <- generic Get
  generic (Put ns {self})

getSelf :: NodeBody s i o NodeId
getSelf = self <$> generic Get

setNeighbours :: [NodeId] -> NodeBody s i o ()
setNeighbours neighbours = do
  ns <- generic Get
  generic (Put ns {neighbours})

getNeighbours :: NodeBody s i o [NodeId]
getNeighbours = neighbours <$> generic Get

getSender :: NodeBody s i o NodeId
getSender = sender <$> generic Get

rpc ::
  NodeId
  -> i
  -> (RpcError -> NodeBody s i o ())
  -> (o -> NodeBody s i o ())
  -> NodeBody s i o ()
rpc nodeId i failure success = do
  -- info $ "RPC to " <> unNodeId nodeId
  generic (Rpc nodeId i failure success)

getNodeTime :: NodeBody s i o Time
getNodeTime = generic GetTime

info :: Text -> NodeBody s i o ()
info text = do
  self <- getSelf
  now <- getNodeTime
  generic
    ( Log
        ("[info] (" <> textShow now <> ") [" <> unNodeId self <> "] " <> text)
    )

after :: Int -> NodeBody s i o () -> NodeBody s i o ()
after micros body = generic (After micros body)

syncRpc ::
  NodeId
  -> i
  -> (RpcError -> NodeBody s i o ())
  -> NodeBody s i o (Either RpcError o)
syncRpc nodeId i failure = do
  varId <- generic NewVar
  generic
    $ Rpc
      nodeId
      i
      failure
      (\o -> generic_ (DeliverVar varId o))
  generic (AwaitVar varId)

------------------------------------------------------------------------

-- start snippet echo
-- data Echo = Echo {echo :: String}
--   deriving stock (Eq, Show, Generic)
--   deriving anyclass (ToJSON, FromJSON)
--
-- data Echo_Ok = Echo_Ok {echo :: String}
--   deriving stock (Eq, Show, Generic)
--   deriving anyclass (ToJSON, FromJSON)
--
-- echoNode :: Node () Echo Echo_Ok
-- echoNode (Echo input) = reply (Echo_Ok input)
--
reply :: o -> NodeBody s i o ()
reply output = generic (Reply output)

-- end snippet

------------------------------------------------------------------------

-- start snippet initialNodeState
initialNodeState :: s -> NodeState s
initialNodeState s =
  NodeState
    { localState = s
    , self = "uninitialised"
    , nodeTime = epoch
    , neighbours = []
    , sender = "uninitialised"
    , inReplyTo = -1
    }

-- end snippet

--    , nextVarId = 0
--    , rpcs = Map.empty

-- start snippet Codec
data Codec i_ i o_ o = Codec
  { decodeIncoming :: i_ -> Either String (Incoming i o)
  , encodeOutgoing :: Outgoing i o -> o_
  }

-- end snippet

------------------------------------------------------------------------

type Cont s i o =
  (NodeState s, [Effect s i o]) -> (NodeState s, [Effect s i o])

-- start snippet runNode
data Effect s i o
  = SEND NodeId i
  | REPLY o
  | RPC NodeId i (RpcError -> Cont s i o) (o -> Cont s i o)
  | LOG Text
  | AFTER Int (Cont s i o)

instance (Show i, Show o) => Show (Effect s i o) where
  show (SEND nodeId i) = "SEND " <> show nodeId <> show i
  show (REPLY o) = "REPLY " <> show o
  show (RPC nodeId i _failure _success) = "RPC " <> show nodeId <> " " <> show i <> " <failure> <success>"
  show (LOG text) = "LOG " <> show text
  show (AFTER micros _k) = "AFTER " <> show micros <> " <k>"

runNode ::
  Node s i o
  -> NodeState s
  -> i
  -> (NodeState s, [Effect s i o])
runNode node ns i = runNodeBody (node i) (ns, [])

-- end snippet

--

-- start snippet runNodeBody
runNodeBody ::
  forall s i o a.
  NodeBody s i o a
  -> (NodeState s, [Effect s i o])
  -> (NodeState s, [Effect s i o])
runNodeBody (NodeBody m) = iterM go done m
  where
    done ::
      a -> (NodeState s, [Effect s i o]) -> (NodeState s, [Effect s i o])
    done _x (ns, effects) = (ns, effects)

    go ::
      Alg
        (NodeF s i o)
        ((NodeState s, [Effect s i o]) -> (NodeState s, [Effect s i o]))
    go (Reply o k) (ns, acc) = k () (ns, acc <> [REPLY o])
    go (Send nodeId i k) (ns, acc) = k () (ns, acc <> [SEND nodeId i])
    go (Get k) (s, acc) = k s (s, acc)
    go (Put s' k) (s, acc) = k () (s', acc)
    go (Rpc nodeId i failure success k) (ns, acc) =
      k
        ()
        ( ns
        , acc
            <> [ RPC
                  nodeId
                  i
                  (\rpcError -> runNodeBody (failure rpcError))
                  (\o -> runNodeBody (success o))
               ]
        )
    go (Log text k) (ns, acc) = k () (ns, acc <> [LOG text])
    go (GetTime k) (ns, acc) = k ns.nodeTime (ns, acc)
    go (After micros m k) (ns, acc) =
      k () (ns, acc <> [AFTER micros (runNodeBody m)])
    -- end snippet
    --    go (NewVar k) (s, acc) = do
    --      let varId = s.nextVarId
    --      k varId (s {nextVarId = varId + 1}, acc)
    go (DeliverVar varId var x) acc = undefined
    go (AwaitVar varId k) acc = undefined

------------------------------------------------------------------------

-- start snippet eventLoop
data EventLoopState s i o = EventLoopState
  { nextMessageId :: MessageId
  , pendingRpcs :: Map MessageId (o -> Cont s i o)
  , pendingTimers ::
      TimerWheel Time (Maybe MessageId, Cont s i o)
  }

initialEventLoopState :: EventLoopState s i o
initialEventLoopState =
  EventLoopState
    { nextMessageId = 0
    , pendingRpcs = Map.empty
    , pendingTimers = emptyTimerWheel
    }

stepEventLoop ::
  forall s i_ i o_ o.
  (Show s, Show i_, Show i, Show o, Show o_) =>
  Node s i o
  -> Codec i_ i o_ o
  -> Runtime i_ o_
  -> NodeState s
  -> EventLoopState s i o
  -> IO (NodeState s, EventLoopState s i o)
stepEventLoop node codec runtime ns es = do
  -- _now <- runtime.getTime
  -- runtime.log
  --   $ "[debug] "
  --   <> textShow _now
  --   <> " "
  --   <> "eventLoop, pendingTimers: "
  --   <> textShow (map (fmap fst) (toListTimer es.pendingTimers))
  case popTimer es.pendingTimers of
    Nothing -> do
      -- runtime.log
      --   $ "[debug] "
      --   <> textShow _now
      --   <> " "
      --   <> "eventLoop, waiting to receive (with 20s timeout)"
      runtime.receive 20_000_000 >>= \case
        Nothing -> do
          -- NOTE: This `send` is needed for simulation handle, otherwise
          -- the call to `takeMVar outputMVar` in simulationNodeHandle.handle
          -- times out.
          runtime.send []
          return (ns, es)
        Just (arrivalTime, incoming) -> do
          -- _now <- runtime.getTime
          -- runtime.log
          --   $ "[debug] "
          --   <> textShow _now
          --   <> " "
          --   <> "eventLoop, incoming (no timer): "
          --   <> textShow incoming
          (ns', es', outgoing) <-
            handleIncoming
              node
              codec
              runtime
              ns {nodeTime = arrivalTime}
              es
              incoming
          runtime.send outgoing
          return (ns', es')
    Just ((later, (mMessageId, k)), pendingTimers') -> do
      let now = ns.nodeTime
      -- NOTE: The `max 0` is needed because if we pass a negative value to
      -- `timeout` it won't timeout.
      let micros = max 0 (diffTimeMicros later now)
      -- runtime.log
      --   $ "[debug] "
      --   <> textShow now
      --   <> " "
      --   <> "eventLoop, timer at: "
      --   <> textShow later
      --   <> ", in "
      --   <> textShow micros
      --   <> "µs"
      --   <> " "
      --   <> textShow mMessageId
      runtime.receive micros >>= \case
        Nothing -> do
          -- We didn't receive a message within `micros`, and therefor need to
          -- handle the timer.
          let now = ns.nodeTime
          let (ns'', effects) = k (ns {nodeTime = now}, [])
          -- runtime.log
          --   $ "[debug] "
          --   <> textShow now
          --   <> " "
          --   <> "eventLoop, timer triggered: "
          --   <> textShow mMessageId
          --   <> ", effects: "
          --   <> textShow effects
          (es', outgoing) <-
            handleEffects
              runtime
              codec
              ns''
              es {pendingTimers = pendingTimers'}
              effects
          runtime.send outgoing
          -- runtime.log
          --   $ "[debug] "
          --   <> textShow now
          --   <> " "
          --   <> "eventLoop, timer, outgoing: "
          --   <> textShow outgoing
          let es'' = es'
          -- let es'' = es' {pendingTimers = pendingTimers' <> es'.pendingTimers}
          -- let es'' = es' {pendingTimers = pendingTimers' <> es'.pendingTimers}
          -- runtime.log
          --   $ "[debug] "
          --   <> textShow now
          --   <> " "
          --   <> "eventLoop, remaining timers: "
          --   <> textShow (map (fmap fst) (toListTimer es''.pendingTimers))
          return (ns'', es'')
        Just (arrivalTime, incoming) -> do
          -- runtime.log
          --   $ "[debug] "
          --   <> textShow _now
          --   <> " "
          --   <> "eventLoop, incoming before timer, incoming: "
          --   <> textShow incoming
          (ns', es', outgoing) <-
            handleIncoming
              node
              codec
              runtime
              ns {nodeTime = arrivalTime}
              es
              incoming
          runtime.send outgoing
          return (ns', es')

-- XXX: remove Show and debugging code
eventLoop ::
  forall s i_ i o_ o.
  (Show s, Show i_, Show i, Show o, Show o_) =>
  Node s i o
  -> s
  -> Codec i_ i o_ o
  -> Runtime i_ o_
  -> IO ()
eventLoop node initialState codec runtime =
  loop (initialNodeState initialState) initialEventLoopState
    `finally` runtime.close
  where
    loop :: NodeState s -> EventLoopState s i o -> IO ()
    loop ns es = do
      (ns', es') <- stepEventLoop node codec runtime ns es
      loop ns' es'

data SimulationCommand i o
  = Handle Time (Incoming i o)
  | NextTimer
  | AdvanceToTime Time
  deriving stock (Show, Read)

data SimulationResponse i o
  = HandleResponse [Outgoing i o]
  | NextTimerResponse (Maybe Time)
  | AdvanceToTimeResponse [Outgoing i o]
  deriving stock (Show, Read)

simulationRuntime ::
  MVar (Time, Incoming i o)
  -> MVar [Outgoing i o]
  -> IO (Runtime (Incoming i o) (Outgoing i o))
simulationRuntime inputMVar outputMVar = do
  return
    Runtime
      { send = putMVar outputMVar
      , receive = \timeout -> case timeout of
          0 -> return Nothing
          _ -> do
            (arrivalTime, incoming) <- takeMVar inputMVar
            -- now <- readFaketime
            -- assert (now - arrivalTime == 0)
            return (Just (arrivalTime, [incoming]))
      , log = Text.hPutStrLn stderr
      , close = return ()
      }

-- AKA shim
simulationEventLoop ::
  forall s i o.
  (Show s, Show i, Show o, Read i, Read o) =>
  Node s i o
  -> s
  -> IO ()
simulationEventLoop node initialState = do
  inputMVar <- newEmptyMVar
  outputMVar <- newEmptyMVar
  runtime <- simulationRuntime inputMVar outputMVar
  hSetBuffering stdin LineBuffering
  hSetBuffering stdout LineBuffering
  hSetBuffering stderr LineBuffering
  loop
    inputMVar
    outputMVar
    runtime
    (initialNodeState initialState)
    initialEventLoopState
    `finally` runtime.close
  where
    loop ::
      MVar (Time, Incoming i o)
      -> MVar [Outgoing i o]
      -> Runtime (Incoming i o) (Outgoing i o)
      -> NodeState s
      -> EventLoopState s i o
      -> IO ()
    loop inputMVar outputMVar runtime ns es = do
      line <- hGetLine stdin
      case readEither line of
        Right (Handle arrivalTime incoming) -> do
          putMVar inputMVar (arrivalTime, incoming)
          (ns', es') <-
            stepEventLoop node testCodec runtime ns {nodeTime = arrivalTime} es
          outgoing <- takeMVar outputMVar
          hPutStrLn
            stdout
            (show (HandleResponse outgoing))
          loop inputMVar outputMVar runtime ns' es'
        Right NextTimer -> do
          let mNextTimer = TimerWheel.nextTimer es.pendingTimers
          hPutStrLn
            stdout
            (show (NextTimerResponse mNextTimer :: SimulationResponse i o))
          loop inputMVar outputMVar runtime ns es
        Right (AdvanceToTime newTime) -> do
          (ns', es') <-
            stepEventLoop node testCodec runtime ns {nodeTime = newTime} es
          outgoing <- takeMVar outputMVar
          hPutStrLn
            stdout
            (show (AdvanceToTimeResponse outgoing))
          loop inputMVar outputMVar runtime ns' es'
        Left err -> error ("simulationEventLoop, failed to parse input: " <> err)

handleIncoming ::
  forall s i_ i o_ o.
  (Show s, Show i_, Show i, Show o) =>
  Node s i o
  -> Codec i_ i o_ o
  -> Runtime i_ o_
  -> NodeState s
  -> EventLoopState s i o
  -> [i_]
  -> IO (NodeState s, EventLoopState s i o, [o_])
handleIncoming node codec runtime = go []
  where
    go ::
      [[o_]]
      -> NodeState s
      -> EventLoopState s i o
      -> [i_]
      -> IO (NodeState s, EventLoopState s i o, [o_])
    go acc ns es [] = return (ns, es, concatMap reverse acc)
    go acc ns es (i_ : incoming) = do
      case codec.decodeIncoming i_ of
        Left err -> do
          hPutStrLn
            stderr
            ( "Failed to parse input: "
                <> err
                <> "\nbody: "
                <> show i_
                <> "\npendingRpcs: "
                <> show (Map.keys es.pendingRpcs)
            )
          go acc ns es incoming
        Right (InMessage message) -> do
          let now = ns.nodeTime
          let (ns', effects) =
                runNode
                  node
                  ns
                    { sender = message.src
                    , inReplyTo = case message.msgId of
                        Nothing ->
                          error
                            ("handleIncoming: message doesn't have msgId set: " <> show message)
                        Just msgId -> msgId
                    , nodeTime = now
                    }
                  message.body
          -- hPutStrLn stderr ("InMessage, effects: " <> show effects)
          (es', outgoing) <- handleEffects runtime codec ns' es effects
          go (outgoing : acc) ns' es' incoming
        Right (InResponse response) ->
          case Map.lookup response.inReplyTo es.pendingRpcs of
            Nothing -> undefined
            Just k -> do
              let now = ns.nodeTime
              -- hPutStrLn stderr ("Resuming success with state: " <> show ns.localState)
              let (ns', effects) = k response.body (ns {nodeTime = now}, [])
              -- hPutStrLn stderr ("InResponse, effects: " <> show effects)
              let es' =
                    es
                      { pendingRpcs = Map.delete response.inReplyTo (pendingRpcs es)
                      , pendingTimers =
                          filterTimer ((/= Just response.inReplyTo) . fst) (pendingTimers es)
                      }
              (es'', outgoing) <-
                handleEffects
                  runtime
                  codec
                  ns' {sender = response.src}
                  es'
                  effects
              go (outgoing : acc) ns' es'' incoming
        Right InRpcError {} -> undefined

handleEffects ::
  forall i i_ o o_ s.
  Runtime i_ o_
  -> Codec i_ i o_ o
  -> NodeState s
  -> EventLoopState s i o
  -> [Effect s i o]
  -> IO (EventLoopState s i o, [o_])
handleEffects runtime codec ns = go []
  where
    go ::
      [o_]
      -> EventLoopState s i o
      -> [Effect s i o]
      -> IO (EventLoopState s i o, [o_])
    go acc es [] = return (es, acc)
    go acc es (SEND nodeId i : effects) = do
      let messageId = es.nextMessageId
      let outgoing =
            OutMessage
              $ Message
                { src = ns.self
                , dest = nodeId
                , msgId = Just messageId
                , body = i
                }
      go
        (codec.encodeOutgoing outgoing : acc)
        es {nextMessageId = messageId + 1}
        effects
    go acc es (REPLY o : effects) = do
      let messageId = es.nextMessageId
      let outgoing =
            OutResponse
              $ Response
                { src = ns.self
                , dest = ns.sender
                , msgId = Just messageId
                , inReplyTo = ns.inReplyTo
                , body = o
                }
      go
        (codec.encodeOutgoing outgoing : acc)
        es {nextMessageId = messageId + 1}
        effects
    go acc es (RPC nodeId i failure success : effects) = do
      let messageId = es.nextMessageId
      let outgoing =
            OutMessage
              $ Message
                { src = ns.self
                , dest = nodeId
                , msgId = Just messageId
                , body = i
                }
      let now = ns.nodeTime
      let es' =
            es
              { nextMessageId = messageId + 1
              , pendingRpcs = Map.insert messageId success (pendingRpcs es)
              , pendingTimers =
                  insertTimer
                    (addTimeMicros rPC_TIMEOUT_MICROS now)
                    (Just messageId, failure Timeout)
                    es.pendingTimers
              }
      go (codec.encodeOutgoing outgoing : acc) es' effects
    go acc es (LOG text : effects) = do
      runtime.log text
      go acc es effects
    go acc es (AFTER micros k : effects) = do
      let now = ns.nodeTime
      let es' =
            es
              { pendingTimers =
                  insertTimer
                    (addTimeMicros micros now)
                    (Nothing, k)
                    es.pendingTimers
              }
      -- Text.hPutStrLn stderr
      --   $ "INSERTED TIMER AT: "
      --   <> textShow (addTimeMicros micros now)
      --   <> ", pendingTimers: "
      --   <> textShow (map (fmap fst) (toListTimer es'.pendingTimers))
      go acc es' effects

rPC_TIMEOUT_MICROS :: Int
rPC_TIMEOUT_MICROS = 5_000_000 -- 5s.

-- end snippet

-- start snippet consoleRuntime
consoleRuntime :: IO (Runtime ByteString ByteString)
consoleRuntime = do
  hSetBuffering stdin LineBuffering
  hSetBuffering stdout LineBuffering
  hSetBuffering stderr LineBuffering
  return
    Runtime
      { receive = \micros -> Timeout.timeout micros consoleReceive
      , send = consoleSend
      , log = Text.hPutStrLn stderr
      , close = return ()
      }
  where
    consoleReceive :: IO (Time, [ByteString])
    consoleReceive = do
      line <- BS8.hGetLine stdin
      if BS8.null line
        then return (epoch, []) -- XXX: epoch?
        else do
          BS8.hPutStrLn stderr ("consoleRuntime: received: " <> line)
          arrivalTime <- getCurrentTime
          return (arrivalTime, [line])

    consoleSend :: [ByteString] -> IO ()
    consoleSend = mapM_ $ \bytes -> do
      BS8.hPutStrLn stderr ("consoleRuntime: sent: " <> bytes)
      BS8.hPutStrLn stdout bytes

-- end snippet

concurrentConsoleRuntime :: IO (Runtime ByteString ByteString)
concurrentConsoleRuntime = do
  hSetBuffering stdin LineBuffering
  hSetBuffering stdout LineBuffering
  hSetBuffering stderr LineBuffering
  receiveQueue <- newTBQueueIO 128
  sendQueue <- newTBQueueIO 128
  rtid <- forkIO $ forever $ do
    line <- BS8.hGetLine stdin
    if BS8.null line
      then return ()
      else atomically (writeTBQueue receiveQueue line)
  stid <- forkIO $ forever $ do
    bytes <- atomically (readTBQueue sendQueue)
    BS8.hPutStrLn stdout bytes
  return
    Runtime
      { receive = \micros -> Timeout.timeout micros (consoleReceive receiveQueue)
      , send = consoleSend sendQueue
      , log = Text.hPutStrLn stderr
      , close = killThread rtid >> killThread stid
      }
  where
    consoleReceive :: TBQueue ByteString -> IO (Time, [ByteString])
    consoleReceive receiveQueue = do
      line <- atomically (readTBQueue receiveQueue)
      -- BS8.hPutStrLn stderr ("consoleRuntime: received: " <> line)
      arrivalTime <- getCurrentTime
      return (arrivalTime, [line])

    consoleSend :: TBQueue ByteString -> [ByteString] -> IO ()
    consoleSend sendQueue = mapM_ $ \bytes -> do
      -- BS8.hPutStrLn stderr ("consoleRuntime: sent: " <> bytes)
      atomically (writeTBQueue sendQueue bytes)

-- (Generic a, FromJSON a, Json.GFromJSON Json.Zero (Rep a)) =>
jsonCodec ::
  ( Generic i
  , Json.GFromJSON Json.Zero (Rep i)
  , Json.GToJSON' Value Json.Zero (Rep i)
  , Generic o
  , Json.GFromJSON Json.Zero (Rep o)
  , Json.GToJSON' Value Json.Zero (Rep o)
  ) =>
  Codec ByteString i ByteString o
jsonCodec =
  Codec
    { decodeIncoming = Message.decodeIncoming
    , encodeOutgoing = Message.encodeOutgoing
    }

-- start snippet testMain
-- testMain :: IO ()
-- testMain = eventLoop echoNode () echoCodec =<< consoleRuntime

-- end snippet

type Port = Int

-- start snippet prodMain
tcpRuntime ::
  Port -> Map NodeId Port -> IO (Runtime BS8.ByteString BS8.ByteString)
-- end snippet
tcpRuntime = undefined

-- start snippet prodMain

prodMain :: Port -> Map NodeId Port -> IO ()
prodMain port peers = undefined -- eventLoop echoNode () echoCodec =<< tcpRuntime port peers

-- end snippet

-- start snippet pipeNodeHandle

data HandleOutput i o = HandleOutput
  { beforeState :: Text
  , outgoing :: [Outgoing i o]
  , afterState :: Text
  , logs :: [Text]
  }

-- start snippet Runtime

type Timeout = Int

data Runtime i o = Runtime
  { receive :: Timeout -> IO (Maybe (Time, [i]))
  , send :: [o] -> IO ()
  , log :: Text -> IO ()
  , close :: IO ()
  }

-- end snippet

data NodeHandle i o = NodeHandle
  { handle :: Time -> Incoming i o -> IO (HandleOutput i o)
  , nextTimer :: IO (Maybe Time)
  , advanceToTime :: Time -> IO (HandleOutput i o)
  , close :: IO ()
  }

simulationNodeHandle ::
  forall s i o.
  (Show i, Read i, Show o, Read o) =>
  FilePath
  -> [String]
  -> IO (NodeHandle i o)
simulationNodeHandle binaryFilePath arguments = do
  (Just hin, Just hout, _, processHandle) <-
    createProcess
      (proc binaryFilePath arguments)
        { std_in = CreatePipe
        , std_out = CreatePipe
        }
  hSetBuffering hin LineBuffering
  hSetBuffering hout LineBuffering
  hSetBuffering stderr LineBuffering
  return
    NodeHandle
      { handle = \arrivalTime incoming -> do
          hPutStrLn hin (show (Handle arrivalTime incoming))
          hFlush hin
          line <- hGetLine hout
          case readEither line :: Either String (SimulationResponse i o) of
            Right (HandleResponse outgoing) ->
              return
                HandleOutput {beforeState = "", afterState = "", outgoing, logs = []}
            Right _ -> error "simulationNodeHandle, impossible, bad response"
            Left err -> do
              hPutStrLn stderr err
              return
                HandleOutput
                  { beforeState = ""
                  , afterState = ""
                  , outgoing = []
                  , logs = []
                  }
      , nextTimer = do
          hPutStrLn hin (show (NextTimer :: SimulationCommand i o))
          hFlush hin
          line <- hGetLine hout
          case readEither line :: Either String (SimulationResponse i o) of
            Right (NextTimerResponse mTime) -> return mTime
            Right _ -> error "simulationNodeHandle, impossible, bad response"
            Left err -> error ("simulationNodeHandle, nextTimer error: " <> err)
      , advanceToTime = \newTime -> do
          hPutStrLn hin (show (AdvanceToTime newTime :: SimulationCommand i o))
          hFlush hin
          line <- hGetLine hout
          case readEither line :: Either String (SimulationResponse i o) of
            Right (AdvanceToTimeResponse outgoing) ->
              return
                HandleOutput
                  { beforeState = ""
                  , afterState = ""
                  , outgoing
                  , logs = []
                  }
            Right _ -> error "simulationNodeHandle, impossible, bad response"
            Left err -> error ("simulationNodeHandle, advanceToTime error: " <> err)
      , close = terminateProcess processHandle
      }

inProcessSimulationNodeHandle ::
  forall s i o.
  (Show s, Show i, Show o) =>
  Node s i o
  -> s
  -> IO (NodeHandle i o)
inProcessSimulationNodeHandle node initialState = do
  ref <- newIORef (initialNodeState initialState, initialEventLoopState)
  inputMVar <- newEmptyMVar
  outputMVar <- newEmptyMVar
  logsMVar <- newMVar []

  let receive_ :: Timeout -> IO (Maybe (Time, [Incoming i o]))
      receive_ 0 = return Nothing
      receive_ micros = do
        (arrivalTime, incoming) <- takeMVar inputMVar
        -- _now <- readFakeTimeIO fakeTime
        -- Text.putStrLn
        --   $ "[debug] "
        --   <> textShow _now
        --   <> " recieve: advancing time: to "
        --   <> textShow arrivalTime
        --   <> ", and delivering: "
        --   <> textShow
        --     input
        return (Just (arrivalTime, [incoming]))

  let send_ :: [Outgoing i o] -> IO ()
      send_ = putMVar outputMVar

  let nextTimer_ :: IO (Maybe Time)
      nextTimer_ = do
        (_ns, es) <- readIORef ref
        return (TimerWheel.nextTimer es.pendingTimers)

  let runtime :: Runtime (Incoming i o) (Outgoing i o)
      runtime =
        Runtime
          { receive = receive_
          , send = send_
          , log = \text -> modifyMVar_ logsMVar (\texts -> return (texts <> [text]))
          , --  \text -> Text.putStrLn text
            close = return ()
          }

  let step :: Maybe Time -> IO (HandleOutput i o)
      step mTime = do
        (ns, es) <- readIORef ref
        -- NOTE: If we are stepping a timer and there's no pending timers, then we stop.
        if isJust mTime && null es.pendingTimers
          then
            return
              HandleOutput
                { beforeState = ""
                , afterState = ""
                , outgoing = []
                , logs = []
                }
          else do
            -- _now <- readFakeTimeIO fakeTime
            -- runtime.log
            --   $ "[debug] "
            --   <> textShow _now
            --   <> " handle_, before step pendingTimers: "
            --   <> textShow (map (fmap fst) (toListTimer es.pendingTimers))
            let time' = maybe ns.nodeTime id mTime
            (ns', es') <-
              stepEventLoop node testCodec runtime ns {nodeTime = time'} es
            -- _now <- readFakeTimeIO fakeTime
            -- runtime.log
            --   $ "[debug] "
            --   <> textShow _now
            --   <> " handle_, after step pendingTimers: "
            --   <> textShow (map (fmap fst) (toListTimer es'.pendingTimers))
            writeIORef ref (ns', es')
            let stateBefore = ns.localState
            let stateAfter = ns'.localState
            outgoing <- takeMVar outputMVar

            -- runtime.log ("[debug] handle, input outgoing: " <> textShow outgoing)
            logs <- modifyMVar logsMVar (\logs -> return ([], logs))
            return
              HandleOutput
                { beforeState = textShow stateBefore
                , outgoing
                , logs
                , afterState = textShow stateAfter
                }

  let advanceToTime_ :: Time -> IO (HandleOutput i o)
      advanceToTime_ time = step (Just time)

  let handle_ :: Int -> Time -> Incoming i o -> IO (HandleOutput i o)
      handle_ level arrivalTime incoming = do
        -- runtime.log
        --   $ "\n[debug] "
        --   <> textShow _now
        --   <> " ("
        --   <> unNodeId incoming.dest
        --   <> ")"
        --   <> " HANDLE >>>>>>>>>>>>>>>>>>>>>>>>>>>\n"
        -- runtime.log
        --   $ "[debug] "
        --   <> textShow _now
        --   <> " handle_, level: "
        --   <> textShow level
        ok <- tryPutMVar inputMVar (arrivalTime, incoming)

        if ok
          then do
            waiting <- takeMVar inputMVar
            if fst waiting /= arrivalTime && (.src) (snd waiting) == incoming.src
              then error "handle: impossible"
              else return ()
            putMVar inputMVar waiting
            HandleOutput {outgoing, logs, beforeState, afterState} <- step Nothing
            -- _now <- readFakeTimeIO fakeTime
            -- runtime.log
            --   $ "\n[debug] "
            --   <> textShow _now
            --   <> " ("
            --   <> unNodeId incoming.dest
            --   <> ")"
            --   <> " HANDLE 1<<<<<<<<<<<<<<<<<<<<<<<<<<\n"
            return
              ( HandleOutput
                  { beforeState
                  , outgoing
                  , afterState
                  , logs
                  }
              )
          else do
            error "impossible"
  -- Previous call to handle caused a timer to go off.
  -- runtime.log
  --   "[debug] handle_, previous call to handle caused timer to go off"
  -- waiting <- takeMVar inputMVar
  -- runtime.log
  --   ("[debug] handle_, processing waiting: " <> textShow waiting)
  -- putMVar inputMVar waiting

  -- --
  -- -- NOTE: it's important NOT to advance the time here, because we
  -- -- haven't yet got to the point in time when the incoming message
  -- -- arrives.
  -- HandleOutput {outgoing, logs, beforeState} <- step
  -- -- Try again to handle the current input again.
  -- handleOutput <- handle_ (level + 1) arrivalTime incoming

  -- _now <- readFakeTimeIO fakeTime
  -- runtime.log
  --   $ "\n[debug] "
  --   <> textShow _now
  --   <> " ("
  --   <> unNodeId incoming.dest
  --   <> ")"
  --   <> " HANDLE 2<<<<<<<<<<<<<<<<<<<<<<<<<<\n"

  -- return
  --   ( HandleOutput
  --       { beforeState
  --       , outgoing = outgoing <> handleOutput.outgoing
  --       , afterState = handleOutput.afterState
  --       , logs = logs <> handleOutput.logs
  --       }
  --   )

  return
    ( NodeHandle
        { handle = handle_ 0
        , nextTimer = nextTimer_
        , advanceToTime = advanceToTime_
        , close = return ()
        }
    )

-- end snippet

pipeNodeHandle ::
  FilePath
  -> [String]
  -> Codec ByteString i ByteString o
  -> IO (NodeHandle i o)
pipeNodeHandle fp args codec = undefined

--  (Just hin, Just hout, _, processHandle) <-
--    createProcess
--      (proc fp args) {std_in = CreatePipe, std_out = CreatePipe}
--  return
--    NodeHandle
--      { handle = \_arrivalTime incoming -> do
--          LBS8.hPutStr hin (encodeIncoming incoming)
--          BS8.hPutStr hin "\n"
--          hFlush hin
--          line <- BS8.hGetLine hout
--          case decodeOutgoing line of
--            Left err -> hPutStrLn stderr err >> return []
--            Right outgoing -> return [outgoing]
--      , close = terminateProcess processHandle
--      }

-- start snippet simulatorMain
simulatorMain :: IO Bool
simulatorMain = blackboxTest "/path/to/test-main-binary" workload
  where
    -- end snippet

    workload = undefined

------------------------------------------------------------------------

testCodec :: Codec (Incoming i o) i (Outgoing i o) o
testCodec =
  Codec
    { decodeIncoming = Right
    , encodeOutgoing = id
    }
