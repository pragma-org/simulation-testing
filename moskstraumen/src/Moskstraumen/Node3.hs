{-# LANGUAGE DeriveFunctor #-}

module Moskstraumen.Node3 (module Moskstraumen.Node3) where

import Control.Concurrent
import Control.Monad.Cont
import Control.Monad.RWS
import qualified Data.ByteString.Char8 as BS8
import Data.IORef
import Data.List (sort)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.Text.IO as Text
import Data.Time
import Debug.Trace
import System.IO
import System.Timeout (timeout)

import Moskstraumen.Codec
import Moskstraumen.Message
import Moskstraumen.NodeId
import Moskstraumen.Parse
import Moskstraumen.Prelude
import Moskstraumen.Pretty

------------------------------------------------------------------------

data NodeF state input output x
  = GetNodeId (NodeId -> x)
  | GetPeers ([NodeId] -> x)
  | SetPeers [NodeId] x
  | GetSender (NodeId -> x)
  | Send NodeId input x
  | Reply output x
  | RPC
      NodeId
      input
      (Node state input output)
      (output -> Node state input output)
      x
  | Log Text x
  | After Int (Node state input output) x
  | GetState (state -> x)
  | PutState state x
  | NewVar (VarId -> x)
  | DeliverVar VarId output x
  | AwaitVar VarId (output -> x)
  deriving (Functor)

newtype VarId = VarId Word64
  deriving newtype (Eq, Ord, Num, Show)

data Free f x
  = Pure x
  | Free (f (Free f x))

type Node' state input output a = Free (NodeF state input output) a

type Node state input output = Free (NodeF state input output) ()

------------------------------------------------------------------------

instance (Functor f) => Functor (Free f) where
  fmap = liftM

instance (Functor f) => Applicative (Free f) where
  pure = Pure
  (<*>) = ap

instance (Functor f) => Monad (Free f) where
  return = pure
  Pure x >>= k = k x
  Free m >>= k = Free (fmap (>>= k) m)

------------------------------------------------------------------------

getNodeId :: Node' state input output NodeId
getNodeId = Free (GetNodeId Pure)

getPeers :: Node' state input output [NodeId]
getPeers = Free (GetPeers Pure)

setPeers :: [NodeId] -> Node state input output
setPeers neighbours = Free (SetPeers neighbours (Pure ()))

send :: NodeId -> input -> Node state input output
send toNodeId input = Free (Send toNodeId input (Pure ()))

getSender :: Node' state input output NodeId
getSender = Free (GetSender Pure)

reply :: output -> Node state input output
reply output = Free (Reply output (Pure ()))

rpc ::
  NodeId
  -> input
  -> Node state input output
  -> (output -> Node state input output)
  -> Node state input output
rpc toNodeId input failure success =
  Free (RPC toNodeId input failure success (Pure ()))

newVar :: Node' state input output VarId
newVar = Free (NewVar Pure)

deliverVar :: VarId -> a -> Node state input a
deliverVar varId output = Free (DeliverVar varId output (Pure ()))

awaitVar :: VarId -> Node' state input output output
awaitVar varId = Free (AwaitVar varId Pure)

syncRpc ::
  NodeId
  -> input
  -> Node state input output
  -> Node' state input output output
syncRpc toNodeId input failure = do
  var <- newVar
  rpc toNodeId input failure $ \output -> do
    deliverVar var output
  awaitVar var

info :: Text -> Node state input output
info text = Free (Log text (Pure ()))

after :: Int -> Node state input output -> Node state input output
after millis task = Free (After millis task (Pure ()))

every :: Int -> Node state input output -> Node state input output
every millis task = after millis (task >> every millis task)

getState :: Node' state input output state
getState = Free (GetState Pure)

putState :: state -> Node state input output
putState state = Free (PutState state (Pure ()))

modifyState :: (state -> state) -> Node state input output
modifyState f = do
  state <- getState
  putState (f state)

------------------------------------------------------------------------

example :: Node Text Int Bool
example = do
  send "n1" 42
  reply True
  rpc
    "n2"
    1
    (info "failed")
    (\b -> if b then send "n2" 2 else send "n2" 3)
  info "good night"
  after 10000
    $ info "good morning"
  every 20000 (info "hi")
  text <- getState
  info text
  putState (text <> text)
  sender <- getSender
  info ("sender: " <> unNodeId sender)

------------------------------------------------------------------------

newtype TimerId = TimerId Word64
  deriving newtype (Eq, Ord, Num, Show)

data Event = MessageEvent Message | TimerEvent TimerId | ExitEvent
  deriving (Eq)

data Effect
  = SEND Message
  | LOG Text
  | TIMER TimerId Int

data NodeContext state input output = NodeContext
  { request :: Message
  , validateMarshal :: ValidateMarshal input output
  }

data NodeState state input output = NodeState
  { self :: NodeId
  , neighbours :: [NodeId]
  , timers :: Map TimerId (Node state input output)
  , rpcs :: Map MessageId (output -> Node state input output)
  , vars :: Map VarId output
  , awaits :: Map VarId (output -> SomeNode state input output)
  , nextMessageId :: MessageId
  , nextTimerId :: TimerId
  , nextVarId :: VarId
  , state :: state
  }

data SomeNode state input output
  = forall a. SomeNode (Node' state input output a)

initialNodeState :: state -> NodeState state input output
initialNodeState initialState =
  NodeState
    { self = "uninitialised"
    , neighbours = []
    , timers = Map.empty
    , rpcs = Map.empty
    , vars = Map.empty
    , awaits = Map.empty
    , nextMessageId = 0
    , nextTimerId = 0
    , nextVarId = 0
    , state = initialState
    }

runNode ::
  Node state input output
  -> NodeContext state input output
  -> NodeState state input output
  -> (NodeState state input output, [Effect])
runNode node = execRWS (runNode' node)

runNode' ::
  Node' state input output a
  -> RWS
      (NodeContext state input output)
      [Effect]
      (NodeState state input output)
      (Maybe a)
runNode' (Pure x) = return (Just x)
runNode' (Free (GetNodeId rest)) = do
  nodeState <- get
  runNode' (rest nodeState.self)
runNode' (Free (GetPeers rest)) = do
  nodeState <- get
  runNode' (rest nodeState.neighbours)
runNode' (Free (SetPeers myNeighbours rest)) = do
  modify (\nodeState -> nodeState {neighbours = myNeighbours})
  runNode' rest
runNode' (Free (GetSender rest)) = do
  nodeContext <- ask
  runNode' (rest nodeContext.request.src)
runNode' (Free (Send toNodeId input rest)) = do
  nodeContext <- ask
  nodeState <- get
  let (kind_, fields_) = nodeContext.validateMarshal.marshalInput input
  tell
    [ SEND
        ( Message
            { src = nodeState.self
            , dest = toNodeId
            , body =
                Payload
                  { kind = kind_
                  , msgId = Nothing
                  , inReplyTo = Nothing
                  , fields = Map.fromList fields_
                  }
            }
        )
    ]
  runNode' rest
runNode' (Free (Reply output rest)) = do
  nodeContext <- ask
  nodeState <- get
  let toNodeId = nodeContext.request.src
  let (kind_, fields_) = nodeContext.validateMarshal.marshalOutput output
  tell
    [ SEND
        ( Message
            { src = nodeState.self
            , dest = nodeContext.request.src
            , body =
                Payload
                  { kind = kind_
                  , msgId = nodeContext.request.body.msgId
                  , inReplyTo = nodeContext.request.body.msgId
                  , fields = Map.fromList fields_
                  }
            }
        )
    ]
  runNode' rest
runNode' (Free (RPC toNodeId input failure success rest)) = do
  nodeContext <- ask
  nodeState <- get
  let messageId = nodeState.nextMessageId
  let (kind_, fields_) = nodeContext.validateMarshal.marshalInput input
  tell
    [ SEND
        ( Message
            { src = nodeState.self
            , dest = toNodeId
            , body =
                Payload
                  { kind = kind_
                  , msgId = Just messageId
                  , inReplyTo = Nothing
                  , fields = Map.fromList fields_
                  }
            }
        )
    ]
  let timerId = nodeState.nextTimerId
  let rpcTimeoutMicros = 5_000_000
  tell [TIMER timerId rpcTimeoutMicros]
  put
    nodeState
      { rpcs = Map.insert messageId success nodeState.rpcs
      , timers = Map.insert timerId failure nodeState.timers
      , nextMessageId = messageId + 1
      , nextTimerId = timerId + 1
      }
  runNode' rest
runNode' (Free (Log text rest)) = do
  tell [LOG text]
  runNode' rest
runNode' (Free (After micros timeout rest)) = do
  nodeState <- get
  let timerId = nodeState.nextTimerId
  tell [TIMER timerId micros]
  put
    nodeState
      { timers = Map.insert timerId timeout nodeState.timers
      , nextTimerId = timerId + 1
      }
  runNode' rest
runNode' (Free (GetState rest)) = do
  nodeState <- get
  runNode' (rest nodeState.state)
runNode' (Free (PutState state' rest)) = do
  modify (\nodeState -> nodeState {state = state'})
  runNode' rest
runNode' (Free (NewVar rest)) = do
  nodeState <- get
  let varId = nodeState.nextVarId
  put nodeState {nextVarId = nodeState.nextVarId + 1}
  runNode' (rest varId)
runNode' (Free (DeliverVar varId output rest)) = do
  nodeState <- get
  case Map.lookup varId nodeState.awaits of
    Nothing -> do
      traceM ("no awaits for: " ++ show varId)
      put nodeState {vars = Map.insert varId output nodeState.vars}
      runNode' rest
    Just continuation -> case continuation output of
      SomeNode node -> do
        traceM "running cont"
        runNode' node
        traceM "running rest"
        runNode' rest
runNode' (Free (AwaitVar varId success)) = do
  -- XXX: timeout and failure
  nodeState <- get
  case lookupDelete varId nodeState.vars of
    Nothing -> do
      put
        nodeState
          { awaits = Map.insert varId (SomeNode . success) nodeState.awaits
          }
      traceM $ "awaiting: " ++ show varId
      return Nothing
    Just (output, vars') -> do
      put nodeState {vars = vars'}
      runNode' (success output)

------------------------------------------------------------------------

data Runtime m = Runtime
  { source :: m Event
  , sink :: Effect -> m ()
  }

data ValidateMarshal input output = ValidateMarshal
  { validateInput :: Parser input
  , validateOutput :: Parser output
  , marshalInput :: Pretty input
  , marshalOutput :: Pretty output
  }

eventLoop ::
  forall m state input output.
  (Monad m) =>
  (input -> Node state input output)
  -> state
  -> ValidateMarshal input output
  -> Runtime m
  -> m ()
eventLoop node initialState validateMarshal runtime =
  loop (initialNodeState initialState)
  where
    loop nodeState = do
      event <- runtime.source
      if event == ExitEvent
        then return ()
        else do
          let (nodeState', effects) = handleEvent event nodeState
          mapM_ runtime.sink effects
          loop nodeState'
      where
        handleEvent ::
          Event
          -> NodeState state input output
          -> (NodeState state input output, [Effect])
        handleEvent (MessageEvent message) nodeState = do
          let nodeContext =
                NodeContext
                  { request = message
                  , validateMarshal = validateMarshal
                  }
          case lookupRPC message.body.inReplyTo nodeState.rpcs of
            Nothing -> case runParser validateMarshal.validateInput message of
              Just input ->
                case handleInit message of
                  Nothing -> runNode (node input) nodeContext nodeState
                  Just myNodeId ->
                    runNode
                      (node input)
                      nodeContext
                      nodeState {self = myNodeId}
              Nothing -> error "eventLoop, failed to parse input"
            Just (continuation, rpcs') ->
              case runParser validateMarshal.validateOutput message of
                Just output -> do
                  runNode
                    (continuation output)
                    nodeContext
                    nodeState {rpcs = rpcs'}
                Nothing -> error "eventLoop, failed to parse output"
        handleEvent (TimerEvent timerId) nodeState =
          case lookupDelete timerId nodeState.timers of
            Nothing -> (nodeState, [])
            Just (node', timers') -> do
              -- XXX: Is there a better way to deal with this?
              let nodeContext =
                    NodeContext
                      { request =
                          Message
                            { src = "dummy"
                            , dest = "dummy"
                            , body =
                                Payload
                                  { kind = "reply cannot be used in timers"
                                  , msgId = Nothing
                                  , inReplyTo = Nothing
                                  , fields = Map.empty
                                  }
                            }
                      , validateMarshal = validateMarshal
                      }
              runNode node' nodeContext nodeState {timers = timers'}
        handleEvent ExitEvent _nodeState = error "not reachable"

        handleInit :: Message -> Maybe NodeId
        handleInit message = case message.body.kind of
          "init" -> case Map.lookup "node_id" message.body.fields of
            Just (String myNodeId) -> Just (NodeId myNodeId)
            _otherwise -> Nothing
          _otherwise -> Nothing

        lookupRPC ::
          Maybe MessageId
          -> Map MessageId (output -> Node state input output)
          -> Maybe
              ( output -> Node state input output
              , Map MessageId (output -> Node state input output)
              )
        lookupRPC Nothing _pendingRpcs = Nothing
        lookupRPC (Just inReplyToMessageId) pendingRpcs =
          lookupDelete inReplyToMessageId pendingRpcs

------------------------------------------------------------------------

-- XXX: Use a heap instead.
data TimerWheel time = TimerWheel [(time, TimerId)]

newTimerWheel :: TimerWheel time
newTimerWheel = TimerWheel []

insertTimer ::
  (Ord time) => time -> TimerId -> TimerWheel time -> TimerWheel time
insertTimer time timerId (TimerWheel agenda) =
  TimerWheel (sort ((time, timerId) : agenda))

deleteTimer :: TimerId -> TimerWheel time -> TimerWheel time
deleteTimer timerId (TimerWheel agenda) =
  TimerWheel (filter ((/= timerId) . snd) agenda)

nextTimer :: TimerWheel time -> Maybe (time, TimerId)
nextTimer (TimerWheel []) = Nothing
nextTimer (TimerWheel (next : _agenda)) = Just next

------------------------------------------------------------------------

consoleRuntime :: Codec -> IO (Runtime IO)
consoleRuntime codec = do
  timerWheelRef <- newIORef newTimerWheel
  return
    Runtime
      { source = consoleSource timerWheelRef
      , sink = consoleSink timerWheelRef
      }
  where
    consoleSource :: IORef (TimerWheel UTCTime) -> IO Event
    consoleSource timerWheelRef = do
      timerWheel <- readIORef timerWheelRef

      let decodeMessage line = case codec.decode line of
            Right message -> return (MessageEvent message)
            Left err ->
              error
                $ "consoleSource: failed to decode message: "
                ++ show err

      case nextTimer timerWheel of
        Nothing -> do
          line <- BS8.hGetLine stdin
          decodeMessage line
        Just (time, timerId) -> do
          now <- getCurrentTime
          let nanos = realToFrac (diffUTCTime time now)
              micros = round (nanos * 1_000_000)
          -- NOTE: `timeout 0` times out immediately while negative values
          -- don't, hence the `max 0`.
          mLine <- timeout (max 0 micros) (BS8.hGetLine stdin)
          case mLine of
            Nothing -> do
              writeIORef timerWheelRef (deleteTimer timerId timerWheel)
              return (TimerEvent timerId)
            Just line -> decodeMessage line

    consoleSink :: IORef (TimerWheel UTCTime) -> Effect -> IO ()
    consoleSink _timerWheelRef (SEND message) = do
      BS8.hPutStr stdout (codec.encode message)
      BS8.hPutStr stdout "\n"
      hFlush stdout
    consoleSink _timerWheelRef (LOG text) = do
      Text.hPutStr stderr text
      Text.hPutStr stderr "\n"
      hFlush stderr
    consoleSink timerWheelRef (TIMER timerId micros) = do
      now <- getCurrentTime
      let later = addUTCTime (realToFrac (fromIntegral micros / 1_000_000)) now
      modifyIORef' timerWheelRef (insertTimer later timerId)

------------------------------------------------------------------------

consoleEventLoop ::
  (input -> Node state input output)
  -> state
  -> ValidateMarshal input output
  -> IO ()
consoleEventLoop node initialState validateMarshal = do
  runtime <- consoleRuntime jsonCodec
  eventLoop node initialState validateMarshal runtime

------------------------------------------------------------------------

testRuntime :: [Message] -> Codec -> IO (Runtime IO)
testRuntime initialMessages codec = do
  messagesRef <- newIORef initialMessages
  timerWheelRef <- newIORef newTimerWheel
  return
    Runtime
      { source = testSource messagesRef timerWheelRef
      , sink = consoleSink timerWheelRef
      }
  where
    testSource :: IORef [Message] -> IORef (TimerWheel UTCTime) -> IO Event
    testSource messagesRef timerWheelRef = do
      messages <- readIORef messagesRef
      timerWheel <- readIORef timerWheelRef
      case nextTimer timerWheel of
        Nothing -> case messages of
          [] -> return ExitEvent
          (message : messages') -> do
            writeIORef messagesRef messages'
            return (MessageEvent message)
        Just (time, timerId) ->
          case messages of
            [] -> do
              writeIORef timerWheelRef (deleteTimer timerId timerWheel)
              now <- getCurrentTime
              let nanos = realToFrac (diffUTCTime time now)
                  micros = round (nanos * 1_000_000)
              threadDelay micros

              return (TimerEvent timerId)
            (message : messages') -> do
              now <- getCurrentTime
              let nanos = realToFrac (diffUTCTime time now)
                  micros = round (nanos * 1_000_000)
              print micros
              if micros <= 0
                then do
                  writeIORef timerWheelRef (deleteTimer timerId timerWheel)
                  return (TimerEvent timerId)
                else do
                  putStrLn "sleeping"
                  threadDelay micros
                  writeIORef messagesRef messages'
                  return (MessageEvent message)

    consoleSink :: IORef (TimerWheel UTCTime) -> Effect -> IO ()
    consoleSink _timerWheelRef (SEND message) = do
      BS8.hPutStr stdout (codec.encode message)
      BS8.hPutStr stdout "\n"
      hFlush stdout
    consoleSink _timerWheelRef (LOG text) = do
      Text.hPutStr stderr text
      Text.hPutStr stderr "\n"
      hFlush stderr
    consoleSink timerWheelRef (TIMER timerId micros) = do
      now <- getCurrentTime
      let later = addUTCTime (realToFrac (fromIntegral micros / 1_000_000)) now
      hPutStrLn stderr ("TIMER:" ++ show (now, later))
      modifyIORef' timerWheelRef (insertTimer later timerId)

testEventLoop ::
  (input -> Node state input output)
  -> state
  -> ValidateMarshal input output
  -> [Message]
  -> IO ()
testEventLoop node initialState validateMarshal initialMessages = do
  runtime <- testRuntime initialMessages jsonCodec
  eventLoop node initialState validateMarshal runtime

example2 :: Node () () Int
example2 = do
  info "starting"
  x <- newVar
  after 1_000_000 $ do
    info "delivering x"
    deliverVar x 3
  info "awaiting..."
  i <- awaitVar x
  info "done waiting"
  info (fromString (show i))

unit_example2 = do
  testEventLoop
    (const example2)
    ()
    ( ValidateMarshal
        { validateInput = return ()
        , validateOutput = return 0
        , marshalInput = const ("i", [])
        , marshalOutput = const ("o", [])
        }
    )
    [ Message
        { src = "c1"
        , dest = "n1"
        , body =
            Payload
              { kind = "init"
              , msgId = Nothing
              , inReplyTo = Nothing
              , fields = Map.fromList [("node_id", String "n1")]
              }
        }
    ]

t = unit_example2
