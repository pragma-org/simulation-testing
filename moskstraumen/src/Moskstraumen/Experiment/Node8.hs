module Moskstraumen.Experiment.Node8 (module Moskstraumen.Experiment.Node8) where

-- Fork of Node5 where we add RPC.

import Control.Applicative
import Control.Concurrent.STM
import Data.Aeson
import qualified Data.Aeson as Json
import qualified Data.ByteString.Char8 as BS8
import qualified Data.ByteString.Lazy.Char8 as LBS8
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import System.IO
import System.Process
import qualified System.Timeout as Timeout

import Moskstraumen.FreeMonad
import Moskstraumen.NodeHandle (NodeHandle (..), close, handle)
import Moskstraumen.NodeId
import Moskstraumen.Prelude
import Moskstraumen.Simulate
import Moskstraumen.Time
import Moskstraumen.TimerWheel2
import Moskstraumen.VarId

------------------------------------------------------------------------

type Node_ s i o = Node s i o ()

-- start snippet Node

newtype Node s i o a = Node {unNode :: i -> NodeBody s i o a}

newtype NodeBody s i o a = NodeBody {unNodeBody :: Free (NodeF s i o) a}

-- end snippet

-- start snippet NodeF
data NodeF s i o x
  = Reply o (() -> x)
  | Get (s -> x)
  | Put s (() -> x)
  | Send NodeId i (() -> x)
  | Rpc NodeId i (RpcError -> x) (o -> x) ~x
  | -- end snippet
    Fail String
  | NewVar (VarId -> x)
  | forall v. DeliverVar VarId v x
  | forall v. AwaitVar VarId (v -> x)
  | After Int x (() -> x)
  | At Time x (() -> x)

instance Functor (NodeF s i o) where
  fmap f (Reply o k) = Reply o (f . k)
  fmap f (Send nodeId i k) = Send nodeId i (f . k)
  fmap f (Rpc nodeId i failure success x) = Rpc nodeId i (f . failure) (f . success) (f x)
  fmap _f (Fail string) = Fail string
  fmap f (NewVar k) = NewVar (f . k)
  fmap f (DeliverVar varId var x) = DeliverVar varId var (f x)
  fmap f (AwaitVar varId k) = AwaitVar varId (f . k)
  fmap f (After micros task k) = After micros (f task) (f . k)

data RpcError = Timeout
  deriving stock (Generic)
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

syncRpc ::
  NodeId
  -> i
  -> (RpcError -> NodeBody s i o ())
  -> NodeBody s i o (Either RpcError o)
syncRpc nodeId i failure = do
  varId <- generic NewVar
  generic_
    $ Rpc
      nodeId
      i
      (unNodeBody . failure)
      (\o -> unNodeBody $ generic_ (DeliverVar varId o))
  generic (AwaitVar varId)

------------------------------------------------------------------------

-- start snippet echo
echo :: Node () String String ()
echo = Node $ \input -> let output = input in reply output

reply :: o -> NodeBody s i o ()
reply output = NodeBody (Free (Reply output Pure))

-- end snippet

------------------------------------------------------------------------

-- start snippet Message
data Message a = Message
  { src :: NodeId
  , dest :: NodeId
  , msgId :: Maybe MessageId
  , inReplyTo :: Maybe MessageId
  , payload :: a
  }
  deriving stock (Generic, Functor, Foldable, Traversable)
  deriving anyclass (FromJSON, ToJSON)

type MessageId = Word64

-- end snippet

-- start snippet Runtime
data Runtime = Runtime
  { send :: [Message Value] -> IO ()
  , receive :: Int -> IO (Maybe [(Time, Message Value)])
  , getTime :: IO Time
  }

-- end snippet
-- , log :: Text -> m ()
-- , timeout ::
--     Microseconds
--     -> m [(Time, Message)]
--     -> m (Maybe [(Time, Message)])
-- , getCurrentTime :: m Time
-- , shutdown :: m ()

-- start snippet NodeState
data NodeState s = NodeState
  { localState :: s
  , self :: NodeId
  }

-- end snippet
-- , rpcs :: Map MessageId (Message Value -> NodeBody s i o ())
-- , nextVarId :: VarId

-- start snippet initialNodeState
initialNodeState :: s -> NodeState s
initialNodeState s =
  NodeState
    { localState = s
    , self = "uninitialised"
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

runNode ::
  Node s i o a
  -> NodeState s
  -> i
  -> (NodeState s, [Effect s i o])
runNode node s i = runNodeBody (unNode node i) s

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
    go (Get k) (s, acc) = k s.localState (s, acc)
    go (Put s' k) (s, acc) = k () (s {localState = s'}, acc)
    go (Rpc nodeId i failure success k) (ns, acc) =
      k
        ( ns
        , RPC nodeId i (flip failure (ns, acc)) (flip success (ns, acc)) : acc
        )
    -- end snippet
    --    go (NewVar k) (s, acc) = do
    --      let varId = s.nextVarId
    --      k varId (s {nextVarId = varId + 1}, acc)
    go (DeliverVar varId var x) acc = undefined
    go (AwaitVar varId k) acc = undefined

-- go (RPC)
-- \| RPC NodeId i (RpcError -> x) (o -> x) ~x

{-
runNodeBody (Pure ()) _codec _runtime _s _mi = return ()
runNodeBody (Free (Reply o k)) codec runtime s mi = do
  let mv = Message mi.dest mi.src mi.msgId (codec.encodeOutput o)
  runtime.send mv
  runNodeBody (k ()) codec runtime s mi
runNodeBody (Free (Send nid i k)) codec runtime s mi = do
  let m = Message undefined nid undefined
  runtime.send m
  runNodeBody (NodeBody (k ())) codec runtime s mi
runNodeBody (Free (RPC nid i failure success k)) codec runtime s mi = do
  runNodeBody (NodeBody (k ())) codec runtime s mi
 -}

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
  forall s i o. Node_ s i o -> s -> Codec i o -> Runtime -> IO ()
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
              let (es', outgoing) = handleEffects codec undefined ns' es effects
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
            putStrLn ("Failed to parse input: " <> err)
            handleMessages ns es incoming acc
          Right mi -> do
            let (ns', effects) = runNode node ns mi.payload
            let (es', outgoing) = handleEffects codec (void mi) ns' es effects
            handleMessages ns' es' incoming (outgoing : acc)
        Just (msgId', k) -> case traverse codec.decodeOutput message of
          Left err -> do
            putStrLn ("Failed to parse output: " <> err)
            handleMessages ns es incoming acc
          Right mo -> case mo.payload of
            Right o -> do
              let (ns', effects) = k o
              let es' = es {pendingRpcs = Map.delete msgId' (pendingRpcs es)}
              let (es'', outgoing) = handleEffects codec (void mo) ns' es' effects
              handleMessages ns' es'' incoming (outgoing : acc)
            Left rpcError ->
              undefined

handleEffects ::
  forall i o s.
  Codec i o
  -> Message ()
  -> NodeState s
  -> EventLoopState s i o
  -> [Effect s i o]
  -> (EventLoopState s i o, [Message Value])
handleEffects codec incoming ns = go []
  where
    go ::
      [Message Value]
      -> EventLoopState s i o
      -> [Effect s i o]
      -> (EventLoopState s i o, [Message Value])
    go acc es [] = (es, reverse acc)
    go acc es (SEND nodeId i : effects) = do
      let messageId = es.nextMessageId
      let message =
            Message
              { src = ns.self
              , dest = nodeId
              , msgId = Just messageId
              , inReplyTo = Nothing
              , payload = codec.encodeInput i
              }
      go (message : acc) es {nextMessageId = messageId + 1} effects
    go acc es (REPLY o : effects) = do
      let messageId = es.nextMessageId
      let message =
            Message
              { src = ns.self
              , dest = incoming.src
              , msgId = Just messageId
              , inReplyTo = incoming.msgId
              , payload = codec.encodeOutput o
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
              , payload = codec.encodeInput i
              }
      let now = undefined
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
      }
  where
    consoleReceive :: IO [(Time, Message Value)]
    consoleReceive = do
      line <- BS8.hGetLine stdin
      if BS8.null line
        then return []
        else do
          BS8.hPutStrLn stderr ("consoleRuntime: recieved: " <> line)
          case Json.eitherDecodeStrict line of
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
        BS8.hPutStrLn
          stderr
          ("consoleRuntime: sent: " <> LBS8.toStrict (Json.encode message))
        BS8.hPutStrLn stdout (LBS8.toStrict (Json.encode message))

-- end snippet

data FakeTime = FakeTime (TVar Time)

newFakeTime :: Time -> IO FakeTime
newFakeTime time = FakeTime <$> newTVarIO time

readFakeTime :: FakeTime -> STM Time
readFakeTime (FakeTime tvar) = readTVar tvar

readFakeTimeIO :: FakeTime -> IO Time
readFakeTimeIO = atomically . readFakeTime

data TestHandle i o = TestHandle
  { fakeTime :: FakeTime
  , inQueue :: TQueue (Either (Message i) (Message o))
  , outQueue :: TQueue (Either (Message i) (Message o))
  }

testSend :: TestHandle i o -> Time -> NodeId -> i -> IO ()
testSend = undefined

nextMessage = undefined

testRuntime :: (ToJSON i, ToJSON o) => IO (Runtime, TestHandle i o)
testRuntime = do
  fakeTime <- newFakeTime epoch
  incoming <- newTQueueIO
  outgoing <- newTQueueIO
  return
    ( Runtime
        { receive = \micros -> atomically $ do
            start <- readFakeTime fakeTime
            let later = addTimeMicros micros start
            let loop later = do
                  now <- readFakeTime fakeTime
                  (arrivalTime, msg) <- nextMessage incoming
                  -- unGetTQueue
                  if now > later
                    then return Nothing -- Timeout happened.
                    else
                      if now >= arrivalTime
                        then -- Next message got receieved.
                          return (Just [(arrivalTime, msg)])
                        else -- Still waiting.
                          loop later
            loop later
        , send = undefined
        , getTime = readFakeTimeIO fakeTime
        }
    , TestHandle
        { fakeTime = fakeTime
        , inQueue = incoming
        , outQueue = outgoing
        }
    )

echoCodec :: Codec String String
echoCodec =
  Codec
    { decodeInput = \value -> case Json.fromJSON value of
        Json.Success input -> Right input
        Json.Error err -> Left err
    , encodeOutput = Json.toJSON
    , encodeInput = Json.toJSON
    , decodeOutput = \value -> case Json.fromJSON value of
        Json.Success input -> Right input
        Json.Error err -> Left err
    }

-- start snippet testMain
testMain :: IO ()
testMain = eventLoop echo () echoCodec =<< consoleRuntime

-- end snippet

type Port = Int

-- start snippet prodMain
tcpRuntime :: Port -> Map NodeId Port -> IO Runtime
-- end snippet
tcpRuntime = undefined

-- start snippet prodMain

prodMain :: Port -> Map NodeId Port -> IO ()
prodMain port peers = eventLoop echo () echoCodec =<< tcpRuntime port peers

-- end snippet

-- start snippet pipeNodeHandle
pipeNodeHandle :: FilePath -> [String] -> IO NodeHandle
pipeNodeHandle fp args = do
  (Just hin, Just hout, _, processHandle) <-
    createProcess
      (proc fp args) {std_in = CreatePipe, std_out = CreatePipe}
  return
    NodeHandle
      { handle = \_arrivalTime message -> do
          LBS8.hPutStr hin (Json.encode message)
          BS8.hPutStr hin "\n"
          hFlush hin
          line <- BS8.hGetLine hout
          case Json.eitherDecodeStrict line of
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
