{-# LANGUAGE FlexibleContexts #-}

module Moskstraumen.Experiment.Node8 (module Moskstraumen.Experiment.Node8) where

-- Fork of Node5 where we add RPC.

import Control.Applicative
import Control.Concurrent
import Control.Concurrent.STM
import Control.Exception (assert)
import Data.Aeson
import qualified Data.Aeson as Json
import qualified Data.Aeson.Types as Json
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BS8
import qualified Data.ByteString.Lazy.Char8 as LBS8
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.Text.IO as Text
import Debug.Trace
import GHC.Generics (Rep)
import System.IO
import System.Process
import qualified System.Timeout as Timeout

import Moskstraumen.FreeMonad
import Moskstraumen.Message3
import qualified Moskstraumen.Message3 as Message
import Moskstraumen.NodeId
import Moskstraumen.Prelude
import Moskstraumen.Simulate
import Moskstraumen.Time
import Moskstraumen.TimerWheel2
import Moskstraumen.VarId

------------------------------------------------------------------------

-- start snippet Node

type Node s i o = i -> NodeBody s i o ()

newtype NodeBody s i o a = NodeBody {unNodeBody :: Free (NodeF s i o) a}

-- end snippet

-- start snippet NodeState
data NodeState s = NodeState
  { localState :: s
  , self :: NodeId
  , theTime :: Time
  , neighbours :: [NodeId]
  , sender :: NodeId
  , inReplyTo :: MessageId
  }

-- end snippet

-- start snippet NodeF
data NodeF s i o x
  = Reply o (() -> x)
  | Get (NodeState s -> x)
  | Put (NodeState s) (() -> x)
  | Send NodeId i (() -> x)
  | Rpc NodeId i (RpcError -> x) (o -> x) (() -> x)
  | After Int x (() -> x)
  | Log Text (() -> x)
  | GetTime (Time -> x)
  | -- end snippet
    Fail String
  | NewVar (VarId -> x)
  | forall v. DeliverVar VarId v x
  | forall v. AwaitVar VarId (v -> x)
  | At Time x (() -> x)

instance Functor (NodeF s i o) where
  fmap f (Reply o k) = Reply o (f . k)
  fmap f (Get k) = Get (f . k)
  fmap f (Put s' k) = Put s' (f . k)
  fmap f (Send nodeId i k) = Send nodeId i (f . k)
  fmap f (Rpc nodeId i failure success k) = Rpc nodeId i (f . failure) (f . success) (f . k)
  fmap f (After micros task k) = After micros (f task) (f . k)
  fmap f (Log text k) = Log text (f . k)
  fmap f (GetTime k) = GetTime (f . k)
  fmap _f (Fail string) = Fail string
  fmap f (NewVar k) = NewVar (f . k)
  fmap f (DeliverVar varId var x) = DeliverVar varId var (f x)
  fmap f (AwaitVar varId k) = AwaitVar varId (f . k)

instance Functor (NodeBody s i o) where
  fmap f (NodeBody m) = NodeBody (fmap f m)

instance Applicative (NodeBody s i o) where
  pure = NodeBody . Pure
  NodeBody mf <*> NodeBody mx = NodeBody (mf <*> mx)

instance MonadFail (NodeBody s i o) where
  fail = NodeBody . Free . Fail

instance Alternative (NodeBody s i o) where
  empty = fail "empty"
  NodeBody (Free (Fail _)) <|> n = n
  m <|> _n = m

instance MonadPlus (NodeBody s i o) where
  mzero = empty
  mplus = (<|>)

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
  generic (Put ns {self = self})

getSelf :: NodeBody s i o NodeId
getSelf = self <$> generic Get

setNeighbours :: [NodeId] -> NodeBody s i o ()
setNeighbours neighbours = do
  ns <- generic Get
  generic (Put ns {neighbours = neighbours})

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
rpc nodeId i failure success = generic (Rpc nodeId i (unNodeBody . failure) (unNodeBody . success))

getNodeTime :: NodeBody s i o Time
getNodeTime = generic GetTime

info :: Text -> NodeBody s i o ()
info text = do
  now <- getNodeTime
  generic (Log ("[info] (" <> textShow now <> ") " <> text))

sleep :: Int -> NodeBody s i o ()
sleep micros = generic (After micros (Pure ()))

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
      (unNodeBody . failure)
      (\o -> unNodeBody $ generic_ (DeliverVar varId o))
  generic (AwaitVar varId)

------------------------------------------------------------------------

-- start snippet echo
data Echo = Echo {echo :: String}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data Echo_Ok = Echo_Ok {echo :: String}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

echoNode :: Node () Echo Echo_Ok
echoNode (Echo input) = reply (Echo_Ok input)

reply :: o -> NodeBody s i o ()
reply output = NodeBody (Free (Reply output Pure))

-- end snippet

------------------------------------------------------------------------

-- start snippet Runtime

type Timeout = Int

data Runtime i o = Runtime
  { receive :: Timeout -> IO (Maybe [(Time, i)])
  , send :: [o] -> IO ()
  , getTime :: IO Time
  , log :: Text -> IO ()
  }

-- end snippet
-- , log :: Text -> m ()
-- , timeout ::
--     Microseconds
--     -> m [(Time, Message)]
--     -> m (Maybe [(Time, Message)])
-- , getCurrentTime :: m Time
-- , shutdown :: m ()

-- , rpcs :: Map MessageId (Message Value -> NodeBody s i o ())
-- , nextVarId :: VarId

-- start snippet initialNodeState
initialNodeState :: s -> NodeState s
initialNodeState s =
  NodeState
    { localState = s
    , self = "uninitialised"
    , theTime = epoch
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
runNode node s i = runNodeBody (node i) s

-- end snippet

--

-- start snippet runNodeBody
runNodeBody ::
  forall s i o a.
  NodeBody s i o a
  -> NodeState s
  -> (NodeState s, [Effect s i o])
runNodeBody (NodeBody m) ns = iterM go done m (ns, [])
  where
    done ::
      a -> (NodeState s, [Effect s i o]) -> (NodeState s, [Effect s i o])
    done _x (ns, effects) = (ns, effects)

    go ::
      Alg
        (NodeF s i o)
        ((NodeState s, [Effect s i o]) -> (NodeState s, [Effect s i o]))
    go (Reply o k) (ns, acc) = k () (ns, acc <> [REPLY o])
    go (Send nodeId i k) (s, acc) = k () (ns, acc <> [SEND nodeId i])
    go (Get k) (s, acc) = k s (s, acc)
    go (Put s' k) (s, acc) = k () (s', acc)
    go (Rpc nodeId i failure success k) (ns, acc) =
      k
        ()
        ( ns
        , acc <> [RPC nodeId i failure success]
        )
    go (Log text k) (ns, acc) = k () (ns, acc <> [LOG text])
    go (GetTime k) (ns, acc) = k ns.theTime (ns, acc)
    go (After micros _m k) (ns, acc) = (ns, acc <> [AFTER micros (k ())])
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
  , pendingTimers :: TimerWheel Time (NodeState s, Cont s i o)
  }

initialEventLoopState :: EventLoopState s i o
initialEventLoopState =
  EventLoopState
    { nextMessageId = 0
    , pendingRpcs = Map.empty
    , pendingTimers = emptyTimerWheel
    }

-- XXX: remove Show and debugging code
eventLoop ::
  forall s i_ i o_ o.
  (Show i_, Show i, Show o) =>
  Node s i o
  -> s
  -> Codec i_ i o_ o
  -> Runtime i_ o_
  -> IO ()
eventLoop node initialState codec runtime =
  loop (initialNodeState initialState) initialEventLoopState
  where
    loop :: NodeState s -> EventLoopState s i o -> IO ()
    loop ns es = do
      case popTimer es.pendingTimers of
        Nothing -> do
          runtime.receive 10_000_000 >>= \case
            Nothing -> loop ns es
            Just incoming -> do
              (ns', es', outgoing) <- handleIncoming ns es incoming []
              runtime.send outgoing
              loop ns' es'
        Just ((later, (ns', k)), pendingTimers') -> do
          now <- runtime.getTime
          -- NOTE: The `max 0` is needed because if we pass a negative value to
          -- `timeout` it won't timeout.
          let micros = max 0 (diffTimeMicros later now)
          runtime.receive micros >>= \case
            Nothing -> do
              now <- runtime.getTime
              let (ns'', effects) = k (ns' {theTime = now}, [])
              -- traceM $ "timeout triggered, effects: " <> show effects
              (es', outgoing) <- handleEffects runtime codec ns'' es effects
              runtime.send outgoing
              loop ns' es' {pendingTimers = pendingTimers'}
            Just incoming -> do
              (ns', es', outgoing) <- handleIncoming ns es incoming []
              runtime.send outgoing
              loop ns' es'

    handleIncoming ::
      NodeState s
      -> EventLoopState s i o
      -> [(Time, i_)]
      -> [[o_]]
      -> IO (NodeState s, EventLoopState s i o, [o_])
    handleIncoming ns es [] acc = return (ns, es, concatMap reverse acc)
    handleIncoming ns es ((_time, i_) : incoming) acc = do
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
          handleIncoming ns es incoming acc
        Right (InMessage message) -> do
          now <- runtime.getTime
          let (ns', effects) =
                runNode
                  node
                  ns
                    { sender = message.src
                    , inReplyTo = case message.msgId of
                        Nothing -> undefined
                        Just msgId -> msgId
                    , theTime = now
                    }
                  message.body
          -- hPutStrLn stderr ("InMessage, effects: " <> show effects)
          (es', outgoing) <- handleEffects runtime codec ns' es effects
          handleIncoming ns' es' incoming (outgoing : acc)
        Right (InResponse response) ->
          case Map.lookup response.inReplyTo es.pendingRpcs of
            Nothing -> undefined
            Just k -> do
              now <- runtime.getTime
              let (ns', effects) = k response.body (ns {theTime = now}, [])
              -- hPutStrLn stderr ("InResponse, effects: " <> show effects)
              let es' = es {pendingRpcs = Map.delete response.inReplyTo (pendingRpcs es)}
              (es'', outgoing) <-
                handleEffects
                  runtime
                  codec
                  ns' {sender = response.src}
                  es'
                  effects
              handleIncoming ns' es'' incoming (outgoing : acc)
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
      now <- runtime.getTime
      let es' =
            es
              { nextMessageId = messageId + 1
              , pendingRpcs = Map.insert messageId success (pendingRpcs es)
              , pendingTimers =
                  insertTimer
                    (addTimeMicros rPC_TIMEOUT_MICROS now)
                    (ns, failure Timeout)
                    (pendingTimers es)
              }
      go (codec.encodeOutgoing outgoing : acc) es' effects
    go acc es (LOG text : effects) = do
      runtime.log text
      go acc es effects
    go acc es (AFTER micros k : effects) = do
      now <- runtime.getTime
      let es' =
            es
              { pendingTimers =
                  insertTimer
                    (addTimeMicros micros now)
                    (ns, k)
                    (pendingTimers es)
              }
      go acc es' effects

rPC_TIMEOUT_MICROS :: Int
rPC_TIMEOUT_MICROS = 1_000_000 -- 1s.

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
      , getTime = getCurrentTime
      , log = Text.hPutStrLn stderr
      }
  where
    consoleReceive :: IO [(Time, ByteString)]
    consoleReceive = do
      line <- BS8.hGetLine stdin
      if BS8.null line
        then return []
        else do
          BS8.hPutStrLn stderr ("consoleRuntime: received: " <> line)
          now <- getCurrentTime
          return [(now, line)]

    consoleSend :: [ByteString] -> IO ()
    consoleSend = mapM_ $ \bytes -> do
      BS8.hPutStrLn stderr ("consoleRuntime: sent: " <> bytes)
      BS8.hPutStrLn stdout bytes

-- end snippet

data FakeTime = FakeTime (TVar Time)

newFakeTime :: Time -> IO FakeTime
newFakeTime time = FakeTime <$> newTVarIO time

readFakeTime :: FakeTime -> STM Time
readFakeTime (FakeTime tvar) = readTVar tvar

writeFakeTime :: FakeTime -> Time -> STM ()
writeFakeTime (FakeTime tvar) newTime = writeTVar tvar newTime

readFakeTimeIO :: FakeTime -> IO Time
readFakeTimeIO = atomically . readFakeTime

data TestHandle i o = TestHandle
  { fakeTime :: FakeTime
  , inQueue :: TQueue (Time, Incoming i o)
  , outQueue :: TQueue (Outgoing i o)
  }

nextMessage :: TQueue (Time, Incoming i o) -> STM (Time, Incoming i o)
nextMessage = readTQueue

testRuntime ::
  forall i o.
  IO (Runtime (Incoming i o) (Outgoing i o), TestHandle i o)
testRuntime = do
  fakeTime <- newFakeTime epoch
  incoming <- newTQueueIO
  outgoing <- newTQueueIO
  return
    ( Runtime
        { receive = \micros -> do
            start <- readFakeTimeIO fakeTime

            let timeoutTime = addTimeMicros micros start

            let loop :: Time -> STM (Maybe [(Time, Incoming i o)])
                loop timeoutTime = do
                  now <- readFakeTime fakeTime
                  traceM $ "timeoutTime: " <> show timeoutTime <> ", now: " <> show now
                  if timeoutTime < now
                    then return Nothing
                    else do
                      (arrivalTime, msg) <- nextMessage incoming
                      traceM $ "arrivalTime: " <> show arrivalTime
                      if timeoutTime < arrivalTime
                        then
                          if now >= arrivalTime
                            then -- Next message got receieved.
                              return (Just [(arrivalTime, msg)])
                            else do
                              -- Still waiting.
                              unGetTQueue incoming (arrivalTime, msg)
                              loop timeoutTime
                        else
                          if now >= arrivalTime
                            then return (Just [(arrivalTime, msg)])
                            else
                              if now > timeoutTime
                                then do
                                  unGetTQueue incoming (arrivalTime, msg)
                                  return Nothing
                                else do
                                  unGetTQueue incoming (arrivalTime, msg)
                                  loop timeoutTime

            atomically (loop timeoutTime)
        , send = atomically . mapM_ (writeTQueue outgoing)
        , getTime = readFakeTimeIO fakeTime
        , log = Text.hPutStrLn stderr
        }
    , TestHandle
        { fakeTime = fakeTime
        , inQueue = incoming
        , outQueue = outgoing
        }
    )

-- (Generic a, FromJSON a, Json.GFromJSON Json.Zero (Rep a)) =>
jsonCodec ::
  ( Generic i
  , Json.GFromJSON Json.Zero (Rep i)
  , Json.GToJSON' Value Json.Zero (Rep i)
  , ToJSON i
  , Generic o
  , Json.GFromJSON Json.Zero (Rep o)
  , Json.GToJSON' Value Json.Zero (Rep o)
  , ToJSON o
  ) =>
  Codec ByteString i ByteString o
jsonCodec =
  Codec
    { decodeIncoming = Message.decodeIncoming
    , encodeOutgoing = Message.encodeOutgoing
    }

echoCodec :: Codec ByteString Echo ByteString Echo_Ok
echoCodec = undefined

-- start snippet testMain
testMain :: IO ()
testMain = eventLoop echoNode () echoCodec =<< consoleRuntime

-- end snippet

type Port = Int

-- start snippet prodMain
tcpRuntime ::
  Port -> Map NodeId Port -> IO (Runtime BS8.ByteString BS8.ByteString)
-- end snippet
tcpRuntime = undefined

-- start snippet prodMain

prodMain :: Port -> Map NodeId Port -> IO ()
prodMain port peers = eventLoop echoNode () echoCodec =<< tcpRuntime port peers

-- end snippet

-- start snippet pipeNodeHandle
--
-- data NodeHandle = NodeHandle
--  { handle :: Time -> Message Value -> IO [Response Value]
--  , close :: IO ()
--  }
--
-- pipeNodeHandle :: FilePath -> [String] -> IO NodeHandle
-- pipeNodeHandle fp args = do
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
--
-- end snippet

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

test_echo :: IO ()
test_echo = do
  (runtime, testHandle) <- testRuntime
  pid <- forkIO (eventLoop echoNode () testCodec runtime)
  sendTest
    testHandle
    1
    ( Message
        { src = "test"
        , dest = "n1"
        , msgId = Just 5
        , body = Echo "hi"
        }
    )
  expectNoRecv testHandle
  advanceTime testHandle 1
  expectRecv
    testHandle
    ( Response
        { src = "uninitialised"
        , dest = "test"
        , msgId = Just 0
        , inReplyTo = 5
        , body = Echo_Ok "hi"
        }
    )

sendTest :: (Show i) => TestHandle i o -> Int -> Message i -> IO ()
sendTest testHandle afterMicros input = do
  hPutStrLn stderr $ ">> sendTest: " <> show input
  atomically $ do
    now <- readFakeTime testHandle.fakeTime
    writeTQueue
      testHandle.inQueue
      (addTimeMicros afterMicros now, InMessage input)

respondTest :: (Show o) => TestHandle i o -> Int -> Response o -> IO ()
respondTest testHandle afterMicros input = do
  hPutStrLn stderr $ ">> respondTest: " <> show input
  atomically $ do
    now <- readFakeTime testHandle.fakeTime
    writeTQueue
      testHandle.inQueue
      (addTimeMicros afterMicros now, InResponse input)

expectRecv ::
  (Eq o, Show i, Show o) => TestHandle i o -> Response o -> IO ()
expectRecv testHandle expectedOutput = do
  atomically (readTQueue testHandle.outQueue) >>= \case
    OutMessage input ->
      error
        ("expectRecv: expected response, but got message:\n" <> show input)
    OutResponse actualOutput ->
      if actualOutput == expectedOutput
        then hPutStrLn stderr $ ">> expectRecv: " <> show expectedOutput
        else
          error
            ( "\nExpected: "
                <> show expectedOutput
                <> "\nGot:      "
                <> show actualOutput
            )

expectRecvMessage ::
  (Eq i, Show i, Show o) => TestHandle i o -> Message i -> IO ()
expectRecvMessage testHandle expectedOutput = do
  atomically (readTQueue testHandle.outQueue) >>= \case
    OutMessage actualOutput ->
      if actualOutput == expectedOutput
        then hPutStrLn stderr $ ">> expectRecvMessage: " <> show expectedOutput
        else
          error
            ( "\nExpected: "
                <> show expectedOutput
                <> "\nGot:      "
                <> show actualOutput
            )
    OutResponse _ -> error "Expecting message, but got reponse"

expectNoRecv :: TestHandle i o -> IO ()
expectNoRecv testHandle =
  assertM =<< atomically (isEmptyTQueue testHandle.outQueue)

advanceTime :: TestHandle i o -> Int -> IO ()
advanceTime testHandle micros = do
  threadDelay 1000
  now <- readFakeTimeIO testHandle.fakeTime
  let later = addTimeMicros micros now
  hPutStrLn stderr
    $ ">> advanceTime, now: "
    <> show now
    <> ", later: "
    <> show later
  atomically $ writeFakeTime testHandle.fakeTime later
  threadDelay 1000
