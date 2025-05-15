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
import qualified Data.ByteString.Char8 as BS8
import qualified Data.ByteString.Lazy.Char8 as LBS8
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.Text.IO as Text
import GHC.Generics (Rep)
import System.IO
import System.Process
import qualified System.Timeout as Timeout

import Moskstraumen.FreeMonad
import Moskstraumen.Message2
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
  , neighbours :: [NodeId]
  , incoming :: Message ()
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
  fmap _f (Fail string) = Fail string
  fmap f (NewVar k) = NewVar (f . k)
  fmap f (DeliverVar varId var x) = DeliverVar varId var (f x)
  fmap f (AwaitVar varId k) = AwaitVar varId (f . k)

data RpcError = Timeout
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON)

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
getSender = src . incoming <$> generic Get

rpc ::
  NodeId
  -> i
  -> (RpcError -> NodeBody s i o ())
  -> (o -> NodeBody s i o ())
  -> NodeBody s i o ()
rpc nodeId i failure success = generic (Rpc nodeId i (unNodeBody . failure) (unNodeBody . success))

info :: Text -> NodeBody s i o ()
info text = generic (Log ("[info] " <> text))

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

data Runtime = Runtime
  { send :: [Message Value] -> IO ()
  , receive :: Timeout -> IO (Maybe [(Time, Message Value)])
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
    , neighbours = []
    , incoming =
        Message
          { src = "dummy"
          , dest = "dummy"
          , msgId = Nothing
          , inReplyTo = Nothing
          , body = ()
          }
    }

-- end snippet

--    , nextVarId = 0
--    , rpcs = Map.empty

-- start snippet Codec
data Codec i o = Codec
  { decodeInput :: Value -> Either String i
  , encodeOutput :: o -> Value
  , encodeInput :: i -> Value
  , decodeOutput :: Value -> Either String (Either RpcError o)
  }

-- end snippet

------------------------------------------------------------------------

-- start snippet runNode
data Effect s i o
  = SEND NodeId i
  | REPLY o
  | RPC
      NodeId
      i
      (RpcError -> (NodeState s, [Effect s i o]))
      (o -> (NodeState s, [Effect s i o]))
  | LOG Text
  | AFTER Int (NodeState s, [Effect s i o])

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
    done _x (ns, messages) = (ns, reverse messages)

    go ::
      Alg
        (NodeF s i o)
        ((NodeState s, [Effect s i o]) -> (NodeState s, [Effect s i o]))
    go (Reply o k) (ns, acc) = k () (ns, REPLY o : acc)
    go (Send nodeId i k) (s, acc) = k () (ns, SEND nodeId i : acc)
    go (Get k) (s, acc) = k s (s, acc)
    go (Put s' k) (s, acc) = k () (s', acc)
    go (Rpc nodeId i failure success k) (ns, acc) =
      k
        ()
        ( ns
        , RPC nodeId i (flip failure (ns, acc)) (flip success (ns, acc)) : acc
        )
    go (Log text k) (s, acc) = k () (s, LOG text : acc)
    go (After micros _m k) (s, acc) = (s, AFTER micros (k () (s, acc)) : acc)
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
  , pendingRpcs :: Map MessageId (o -> (NodeState s, [Effect s i o]))
  , pendingTimers :: TimerWheel Time (NodeState s, [Effect s i o])
  }

initialEventLoopState :: EventLoopState s i o
initialEventLoopState =
  EventLoopState
    { nextMessageId = 0
    , pendingRpcs = Map.empty
    , pendingTimers = emptyTimerWheel
    }

eventLoop ::
  forall s i o. Node s i o -> s -> Codec i o -> Runtime -> IO ()
eventLoop node initialState codec runtime =
  loop (initialNodeState initialState) initialEventLoopState
  where
    loop :: NodeState s -> EventLoopState s i o -> IO ()
    loop ns es = do
      case popTimer es.pendingTimers of
        Nothing -> do
          runtime.receive maxBound >>= \case
            Nothing -> loop ns es
            Just incoming -> do
              (ns', es', outgoing) <- handleMessages ns es incoming []
              runtime.send outgoing
              loop ns' es'
        Just ((later, (ns', effects)), timerWheel') -> do
          now <- runtime.getTime
          -- NOTE: The `max 0` is needed because if we pass a negative value to
          -- `timeout` it won't timeout.
          let micros = max 0 (diffTimeMicros later now)
          runtime.receive micros >>= \case
            Nothing -> do
              (es', outgoing) <-
                handleEffects
                  runtime
                  codec
                  ns'
                  es
                  effects
              runtime.send outgoing
              loop ns' es'
            Just incoming -> do
              (ns', es', outgoing) <- handleMessages ns es incoming []
              runtime.send outgoing
              loop ns' es'

    handleMessages ns es [] acc = return (ns, es, concatMap reverse acc)
    handleMessages ns es ((_time, message) : incoming) acc = do
      case message.msgId >>= \msgId' -> (\k -> (msgId', k)) <$> Map.lookup msgId' es.pendingRpcs of
        Nothing -> case traverse codec.decodeInput message of
          Left err -> do
            hPutStrLn
              stderr
              ("Failed to parse input: " <> err <> "\nbody: " <> show message.body)
            handleMessages ns es incoming acc
          Right mi -> do
            let (ns', effects) = runNode node ns {incoming = void mi} mi.body
            (es', outgoing) <-
              handleEffects runtime codec ns' {incoming = void mi} es effects
            handleMessages ns' es' incoming (outgoing : acc)
        Just (msgId', k) -> case traverse codec.decodeOutput message of
          Left err -> do
            hPutStrLn stderr ("Failed to parse output: " <> err)
            handleMessages ns es incoming acc
          Right mo -> case mo.body of
            Right o -> do
              let (ns', effects) = k o
              let es' = es {pendingRpcs = Map.delete msgId' (pendingRpcs es)}
              (es'', outgoing) <-
                handleEffects runtime codec ns' {incoming = void mo} es' effects
              handleMessages ns' es'' incoming (outgoing : acc)
            Left rpcError ->
              undefined

handleEffects ::
  forall i o s.
  Runtime
  -> Codec i o
  -> NodeState s
  -> EventLoopState s i o
  -> [Effect s i o]
  -> IO (EventLoopState s i o, [Message Value])
handleEffects runtime codec ns = go []
  where
    go ::
      [Message Value]
      -> EventLoopState s i o
      -> [Effect s i o]
      -> IO (EventLoopState s i o, [Message Value])
    go acc es [] = return (es, reverse acc)
    go acc es (SEND nodeId i : effects) = do
      let messageId = es.nextMessageId
      let message =
            Message
              { src = ns.self
              , dest = nodeId
              , msgId = Just messageId
              , inReplyTo = Nothing
              , body = codec.encodeInput i
              }
      go (message : acc) es {nextMessageId = messageId + 1} effects
    go acc es (REPLY o : effects) = do
      let messageId = es.nextMessageId
      let message =
            Message
              { src = ns.self
              , dest = ns.incoming.src
              , msgId = Just messageId
              , inReplyTo = ns.incoming.msgId
              , body = codec.encodeOutput o
              }
      go (message : acc) es {nextMessageId = messageId + 1} effects
    go acc es (RPC nodeId i failure success : effects) = do
      let messageId = es.nextMessageId
      let message =
            Message
              { src = ns.self
              , dest = nodeId
              , msgId = Just messageId
              , inReplyTo = Nothing
              , body = codec.encodeInput i
              }
      now <- runtime.getTime
      let es' =
            es
              { nextMessageId = messageId + 1
              , pendingRpcs = Map.insert messageId success (pendingRpcs es)
              , pendingTimers =
                  insertTimer
                    (addTimeMicros rPC_TIMEOUT_MICROS now)
                    (failure Timeout)
                    (pendingTimers es)
              }
      go (message : acc) es' effects
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
                    k
                    (pendingTimers es)
              }
      go acc es' effects

rPC_TIMEOUT_MICROS :: Int
rPC_TIMEOUT_MICROS = 1_000_000 -- 1s.

-- end snippet

-- start snippet consoleRuntime
consoleRuntime :: IO Runtime
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
    consoleReceive :: IO [(Time, Message Value)]
    consoleReceive = do
      line <- BS8.hGetLine stdin
      if BS8.null line
        then return []
        else do
          BS8.hPutStrLn stderr ("consoleRuntime: recieved: " <> line)
          case decodeMessageValue' line :: Either String (Message Value) of
            Right message -> do
              now <- getCurrentTime
              return [(now, message)]
            Left err ->
              error
                $ "consoleRuntime: failed to decode message: "
                ++ show err
                ++ "\nline: "
                ++ show line

    consoleSend :: [Message Value] -> IO ()
    consoleSend messages =
      forM_ messages $ \message -> do
        let bytes = LBS8.toStrict (encodeMessage message)
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
  , inQueue :: TQueue (Time, Either (Message i) (Message o))
  , outQueue :: TQueue (Either (Message i) (Message o))
  }

nextMessage ::
  TQueue (Time, Either (Message i) (Message o))
  -> STM (Time, Either (Message i) (Message o))
nextMessage = readTQueue

testRuntime ::
  forall i o.
  (ToJSON i, ToJSON o, FromJSON i, FromJSON o) =>
  IO (Runtime, TestHandle i o)
testRuntime = do
  fakeTime <- newFakeTime epoch
  incoming <- newTQueueIO
  outgoing <- newTQueueIO
  let encodeMessage :: Either (Message i) (Message o) -> Message Value
      encodeMessage = either (fmap Json.toJSON) (fmap Json.toJSON)

      decodeMessage :: Message Value -> Either (Message i) (Message o)
      decodeMessage message = case message.inReplyTo of
        Nothing -> case Json.fromJSON message.body of
          Json.Error err -> error err
          Json.Success i -> Left message {body = i}
        Just _ -> case Json.fromJSON message.body of
          Json.Error err -> error err
          Json.Success o -> Right message {body = o}

  return
    ( Runtime
        { receive = \micros -> atomically $ do
            start <- readFakeTime fakeTime
            let timeoutTime = addTimeMicros micros start
            let loop timeoutTime = do
                  now <- readFakeTime fakeTime
                  (arrivalTime, msg) <- nextMessage incoming
                  if timeoutTime < arrivalTime
                    then
                      if now > timeoutTime
                        then do
                          unGetTQueue incoming (arrivalTime, msg)
                          return Nothing -- Timeout happened.
                        else
                          if now >= arrivalTime
                            then -- Next message got receieved.
                              return (Just [(arrivalTime, encodeMessage msg)])
                            else do
                              -- Still waiting.
                              unGetTQueue incoming (arrivalTime, msg)
                              loop timeoutTime
                    else
                      if now >= arrivalTime
                        then return (Just [(arrivalTime, encodeMessage msg)])
                        else
                          if now > timeoutTime
                            then do
                              unGetTQueue incoming (arrivalTime, msg)
                              return Nothing
                            else do
                              unGetTQueue incoming (arrivalTime, msg)
                              loop timeoutTime
            loop timeoutTime
        , send = atomically . mapM_ (writeTQueue outgoing . decodeMessage)
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
  , FromJSON i
  , Json.GFromJSON Json.Zero (Rep i)
  , ToJSON i
  , FromJSON o
  , ToJSON o
  ) =>
  Codec i o
jsonCodec =
  Codec
    { decodeInput = Json.parseEither (Json.genericParseJSON aesonOptions)
    , encodeOutput = Json.toJSON
    , encodeInput = Json.toJSON
    , decodeOutput = \value -> case Json.fromJSON value of
        Json.Success input -> Right input
        Json.Error err -> Left err
    }

echoCodec :: Codec Echo Echo_Ok
echoCodec = jsonCodec

-- start snippet testMain
testMain :: IO ()
testMain = eventLoop echoNode () echoCodec =<< consoleRuntime

-- end snippet

type Port = Int

-- start snippet prodMain
tcpRuntime :: Port -> Map NodeId Port -> IO Runtime
-- end snippet
tcpRuntime = undefined

-- start snippet prodMain

prodMain :: Port -> Map NodeId Port -> IO ()
prodMain port peers = eventLoop echoNode () echoCodec =<< tcpRuntime port peers

-- end snippet

-- start snippet pipeNodeHandle
--
data NodeHandle = NodeHandle
  { handle :: Time -> Message Value -> IO [Message Value]
  , close :: IO ()
  }

pipeNodeHandle :: FilePath -> [String] -> IO NodeHandle
pipeNodeHandle fp args = do
  (Just hin, Just hout, _, processHandle) <-
    createProcess
      (proc fp args) {std_in = CreatePipe, std_out = CreatePipe}
  return
    NodeHandle
      { handle = \_arrivalTime message -> do
          LBS8.hPutStr hin (encodeMessage message)
          BS8.hPutStr hin "\n"
          hFlush hin
          line <- BS8.hGetLine hout
          case decodeMessage' line of
            Left err -> hPutStrLn stderr err >> return []
            Right msg' -> return [msg']
      , close = terminateProcess processHandle
      }

-- end snippet

-- start snippet simulatorMain
simulatorMain :: IO Bool
simulatorMain = blackboxTest "/path/to/test-main-binary" workload
  where
    -- end snippet

    workload = undefined

------------------------------------------------------------------------

test_echo :: IO ()
test_echo = do
  (runtime, testHandle) <- testRuntime
  pid <- forkIO (eventLoop echoNode () echoCodec runtime)
  sendTest
    testHandle
    1
    ( Message
        { src = "test"
        , dest = "n1"
        , msgId = Just 5
        , inReplyTo = Nothing
        , body = Echo "hi"
        }
    )
  expectNoRecv testHandle
  advanceTime testHandle 1
  expectRecv
    testHandle
    ( Message
        { src = "uninitialised"
        , dest = "test"
        , msgId = Just 0
        , inReplyTo = Just 5
        , body = Echo_Ok "hi"
        }
    )

sendTest :: TestHandle i o -> Int -> Message i -> IO ()
sendTest testHandle afterMicros input = atomically $ do
  now <- readFakeTime testHandle.fakeTime
  writeTQueue
    testHandle.inQueue
    (addTimeMicros afterMicros now, Left input)
expectRecv :: (Eq o, Show i) => TestHandle i o -> Message o -> IO ()
expectRecv testHandle expectedOutput = do
  atomically (readTQueue testHandle.outQueue) >>= \case
    Left input -> error (show input)
    Right actualOutput ->
      assertM (actualOutput == expectedOutput)

expectNoRecv :: TestHandle i o -> IO ()
expectNoRecv testHandle =
  assertM =<< atomically (isEmptyTQueue testHandle.outQueue)

advanceTime :: TestHandle i o -> Int -> IO ()
advanceTime testHandle micros = atomically $ do
  now <- readFakeTime testHandle.fakeTime
  writeFakeTime testHandle.fakeTime (addTimeMicros micros now)
