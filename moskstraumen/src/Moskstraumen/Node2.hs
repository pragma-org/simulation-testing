module Moskstraumen.Node2 (module Moskstraumen.Node2) where

import Control.Monad.RWS
import qualified Data.ByteString.Char8 as BS8
import Data.IORef
import Data.List (sort)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.Text.IO as Text
import Data.Time
import System.IO
import System.Timeout (timeout)

import Moskstraumen.Codec
import Moskstraumen.Message
import Moskstraumen.NodeId
import Moskstraumen.Parse
import Moskstraumen.Prelude
import Moskstraumen.Pretty

------------------------------------------------------------------------

data NodeF input output x
  = SetPeers [NodeId] x
  | Send NodeId input x
  | Reply output x
  | RPC NodeId input (Node input output) (output -> Node input output) x
  | Log Text x
  | After Int (Node input output) x

data Node' input output a where
  Pure :: a -> Node' input output a
  (:>>=) ::
    Node' input output a
    -> (a -> Node' input output b)
    -> Node' input output b
  Fix :: NodeF input output (Node' input output a) -> Node' input output a

type Node input output = Node' input output ()

------------------------------------------------------------------------

instance Functor (Node' input output) where
  fmap = liftM

instance Applicative (Node' input output) where
  pure = Pure
  (<*>) = ap

instance Monad (Node' input output) where
  return = pure
  (>>=) = (:>>=)

------------------------------------------------------------------------

setPeers :: [NodeId] -> Node input output
setPeers neighbours = Fix (SetPeers neighbours (Pure ()))

send :: NodeId -> input -> Node input output
send toNodeId input = Fix (Send toNodeId input (Pure ()))

reply :: output -> Node input output
reply output = Fix (Reply output (Pure ()))

rpc ::
  NodeId
  -> input
  -> Node input output
  -> (output -> Node input output)
  -> Node input output
rpc toNodeId input failure success =
  Fix (RPC toNodeId input failure success (Pure ()))

info :: Text -> Node input output
info text = Fix (Log text (Pure ()))

after :: Int -> Node input output -> Node input output
after millis task = Fix (After millis task (Pure ()))

every :: Int -> Node input output -> Node input output
every millis task = after millis (task >> every millis task)

------------------------------------------------------------------------

example :: Node Int Bool
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

------------------------------------------------------------------------

newtype TimerId = TimerId Word64
  deriving newtype (Eq, Ord, Num)

data Event = MessageEvent Message | TimerEvent TimerId

data Effect
  = SEND Message
  | LOG Text
  | TIMER TimerId Int

data NodeContext input output = NodeContext
  { request :: Message
  , validateMarshal :: ValidateMarshal input output
  }

data NodeState input output = NodeState
  { self :: NodeId
  , neighbours :: [NodeId]
  , timers :: Map TimerId (Node input output)
  , rpcs :: Map MessageId (output -> Node input output)
  , nextMessageId :: MessageId
  , nextTimerId :: TimerId
  }

initialNodeState :: NodeState input output
initialNodeState =
  NodeState
    { self = "uninitialised"
    , neighbours = []
    , timers = Map.empty
    , rpcs = Map.empty
    , nextMessageId = 0
    , nextTimerId = 0
    }

runNode ::
  Node input output
  -> NodeContext input output
  -> NodeState input output
  -> (NodeState input output, [Effect])
runNode node = execRWS (runNode' node)

runNode' ::
  Node' input output a
  -> RWS (NodeContext input output) [Effect] (NodeState input output) a
runNode' (Pure x) = return x
runNode' (m :>>= k) = runNode' m >>= runNode' . k
runNode' (Fix (SetPeers myNeighbours rest)) = do
  modify (\nodeState -> nodeState {neighbours = myNeighbours})
  runNode' rest
runNode' (Fix (Send toNodeId input rest)) = do
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
runNode' (Fix (Reply output rest)) = do
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
runNode' (Fix (RPC toNodeId input failure success rest)) = do
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
runNode' (Fix (Log text rest)) = do
  tell [LOG text]
  runNode' rest
runNode' (Fix (After micros timeout rest)) = do
  nodeState <- get
  let timerId = nodeState.nextTimerId
  tell [TIMER timerId micros]
  put
    nodeState
      { timers = Map.insert timerId timeout nodeState.timers
      , nextTimerId = timerId + 1
      }
  runNode' rest

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
  forall m input output.
  (Monad m) =>
  (input -> Node input output)
  -> ValidateMarshal input output
  -> Runtime m
  -> m ()
eventLoop node validateMarshal runtime =
  loop initialNodeState
  where
    loop nodeState = do
      event <- runtime.source
      let (nodeState', effects) = handleEvent event nodeState
      mapM_ runtime.sink effects
      loop nodeState'
      where
        handleEvent ::
          Event -> NodeState input output -> (NodeState input output, [Effect])
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
                  let nodeState' = nodeState {rpcs = rpcs'}
                  runNode
                    (continuation output)
                    nodeContext
                    nodeState'
                Nothing -> error "eventLoop, failed to parse output"
        handleEvent (TimerEvent timerId) nodeState =
          case lookupDelete timerId nodeState.timers of
            Nothing -> (nodeState, [])
            Just (node', timers') -> do
              -- XXX: Is there a better way to deal with this?
              let nodeContext =
                    NodeContext
                      { request = error "reply cannot be used in timers"
                      , validateMarshal = validateMarshal
                      }
              runNode node' nodeContext nodeState {timers = timers'}

        handleInit :: Message -> Maybe NodeId
        handleInit message = case message.body.kind of
          "init" -> case Map.lookup "node_id" message.body.fields of
            Just (String myNodeId) -> Just (NodeId myNodeId)
            _otherwise -> Nothing
          _otherwise -> Nothing

        lookupRPC ::
          Maybe MessageId
          -> Map MessageId (output -> Node input output)
          -> Maybe
              ( output -> Node input output
              , Map MessageId (output -> Node input output)
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
          let nanos = realToFrac (diffUTCTime now time)
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
      let later = addUTCTime (realToFrac (fromIntegral micros / 1_000_000_000)) now
      modifyIORef' timerWheelRef (insertTimer later timerId)

------------------------------------------------------------------------

consoleEventLoop ::
  (input -> Node input output)
  -> ValidateMarshal input output
  -> IO ()
consoleEventLoop node validateMarshal = do
  runtime <- consoleRuntime jsonCodec
  eventLoop node validateMarshal runtime
