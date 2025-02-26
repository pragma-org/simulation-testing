module Moskstraumen.EventLoop2 (module Moskstraumen.EventLoop2) where

import Control.Exception (finally)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Debug.Trace
import System.Environment
import System.Random
import Text.Read (readMaybe)

import Moskstraumen.Codec
import Moskstraumen.Effect
import Moskstraumen.Error
import Moskstraumen.Message
import Moskstraumen.Node4
import Moskstraumen.NodeId
import Moskstraumen.Parse
import Moskstraumen.Prelude
import Moskstraumen.Pretty
import Moskstraumen.Random
import Moskstraumen.Runtime.TCP
import Moskstraumen.Runtime2
import Moskstraumen.Time
import Moskstraumen.TimerWheel2
import Moskstraumen.VarId

------------------------------------------------------------------------

rPC_TIMEOUT_MICROS :: Int
rPC_TIMEOUT_MICROS = 1_000_000 -- 1 second.

------------------------------------------------------------------------

data EventLoopState state input output = EventLoopState
  { rpcs ::
      Map MessageId (Either RPCError output -> Node state input output)
  , nodeState :: NodeState state
  , nextMessageId :: MessageId
  , timerWheel ::
      TimerWheel Time (Maybe MessageId, Node state input output)
  , vars :: Map VarId (Either RPCError output)
  , awaits ::
      Map
        VarId
        (NodeContext, Either RPCError output -> Node state input output)
  , prng :: Prng
  }

initialEventLoopState ::
  NodeState state -> Prng -> EventLoopState state input output
initialEventLoopState initialNodeState initialPrng =
  EventLoopState
    { rpcs = Map.empty
    , nodeState = initialNodeState
    , nextMessageId = 0
    , timerWheel = emptyTimerWheel
    , vars = Map.empty
    , awaits = Map.empty
    , prng = initialPrng
    }

------------------------------------------------------------------------

eventLoop ::
  forall m state input output.
  (Monad m) =>
  (input -> Node state input output)
  -> state
  -> Prng
  -> ValidateMarshal input output
  -> Runtime m
  -> m ()
eventLoop node initialState initialPrng validateMarshal runtime =
  loop
    (initialEventLoopState (initialNodeState initialState) initialPrng)
  where
    loop :: EventLoopState state input output -> m ()
    loop eventLoopState = do
      case popTimer eventLoopState.timerWheel of
        Nothing -> do
          messages <- runtime.receive
          eventLoopState' <- handleMessages messages eventLoopState
          loop eventLoopState'
        Just ((time, (mMessageId, timeoutNode)), timerWheel') -> do
          now <- runtime.getCurrentTime
          let micros = diffTimeMicros time now
          -- traceM ("timer will trigger in: " <> show micros <> " µs")
          runtime.timeout micros runtime.receive >>= \case
            Nothing -> do
              -- The next timer triggered, which means we should run the
              -- effects associated with that timer. Futhermore, if
              -- there's a messageId associated with the timer, it means
              -- that an RPC call timed out and we should remove the
              -- successful continuation from from eventLoopState.rpcs.
              now <- runtime.getCurrentTime
              -- traceM ("timer triggered, now: " <> show now)
              let (prng', prng'') = splitPrng eventLoopState.prng
              let (nodeState', effects) =
                    execNode
                      timeoutNode
                      (NodeContext Nothing now prng')
                      eventLoopState.nodeState
              let eventLoopState' =
                    eventLoopState
                      { nodeState = nodeState'
                      , timerWheel = timerWheel'
                      , prng = prng''
                      }
              eventLoopState'' <- handleEffects effects eventLoopState'
              case mMessageId of
                Nothing -> loop eventLoopState''
                Just messageId ->
                  loop
                    eventLoopState''
                      { rpcs = Map.delete messageId eventLoopState.rpcs
                      }
            Just messages -> do
              eventLoopState' <- handleMessages messages eventLoopState
              loop eventLoopState'

    handleMessages ::
      [(Time, Message)]
      -> EventLoopState state input output
      -> m (EventLoopState state input output)
    handleMessages [] eventLoopState = return eventLoopState
    handleMessages ((_arrivalTime, message) : messages) eventLoopState =
      case message.body.inReplyTo of
        Nothing -> case runParser validateMarshal.validateInput message of
          Nothing -> error ("eventLoop, failed to parse input: " ++ show message)
          Just input -> do
            now <- runtime.getCurrentTime
            traceM ("handleMessages, now: " <> show now)
            let (prng', prng'') = splitPrng eventLoopState.prng
            let (nodeState', effects) =
                  execNode
                    (node input)
                    (NodeContext (Just message) now prng')
                    eventLoopState.nodeState
            eventLoopState' <-
              handleEffects
                effects
                eventLoopState {nodeState = nodeState', prng = prng''}
            handleMessages messages eventLoopState'
        Just inReplyToMessageId ->
          case runParser (rpcErrorParser `alt` validateMarshal.validateOutput) message of
            Nothing ->
              error ("eventLoop, failed to parse output: " ++ show message)
            Just output ->
              case lookupDelete inReplyToMessageId eventLoopState.rpcs of
                Nothing -> do
                  -- We couldn't find the success continuation of the
                  -- RPC. This happens when the failure timer is
                  -- triggered, and the RPC is removed.
                  -- XXX: Collect metrics / log?
                  return eventLoopState
                Just (success, rpcs') -> do
                  now <- runtime.getCurrentTime
                  let (prng', prng'') = splitPrng eventLoopState.prng
                  let (nodeState', effects) =
                        execNode
                          (success output)
                          (NodeContext (Just message) now prng')
                          eventLoopState.nodeState
                  eventLoopState' <-
                    handleEffects
                      effects
                      eventLoopState {nodeState = nodeState', rpcs = rpcs', prng = prng''}

                  return
                    eventLoopState'
                      { timerWheel =
                          filterTimer
                            ((/= (Just inReplyToMessageId)) . fst)
                            eventLoopState.timerWheel
                      }

    handleEffects ::
      [Effect (Node' state input output) input output]
      -> EventLoopState state input output
      -> m (EventLoopState state input output)
    handleEffects [] eventLoopState = return eventLoopState
    handleEffects (effect : effects) eventLoopState = do
      case effect of
        SEND srcNodeId destNodeId input -> do
          let (kind_, fields_) = validateMarshal.marshalInput input
          let message =
                Message
                  { src = srcNodeId
                  , dest = destNodeId
                  , body =
                      Payload
                        { kind = kind_
                        , msgId = Nothing
                        , inReplyTo = Nothing
                        , fields = Map.fromList fields_
                        }
                  }
          runtime.send message
          handleEffects effects eventLoopState
        REPLY srcNodeId destNodeId mMessageId output -> do
          let (kind_, fields_) =
                either
                  marshalRPCError
                  validateMarshal.marshalOutput
                  output
          let message =
                Message
                  { src = srcNodeId
                  , dest = destNodeId
                  , body =
                      Payload
                        { kind = kind_
                        , msgId = mMessageId
                        , inReplyTo = mMessageId
                        , fields = Map.fromList fields_
                        }
                  }
          runtime.send message
          handleEffects effects eventLoopState
        SET_TIMER micros mMessageId timeoutNode -> do
          now <- runtime.getCurrentTime
          let later = addTimeMicros micros now
          let timerWheel' =
                insertTimer
                  later
                  (Nothing, timeoutNode)
                  eventLoopState.timerWheel
          handleEffects effects eventLoopState {timerWheel = timerWheel'}
        LOG text -> do
          runtime.log text
          handleEffects effects eventLoopState
        DO_RPC srcNodeId destNodeId input failure success -> do
          let messageId = eventLoopState.nextMessageId
          let (kind_, fields_) = validateMarshal.marshalInput input
          let message =
                Message
                  { src = srcNodeId
                  , dest = destNodeId
                  , body =
                      Payload
                        { kind = kind_
                        , msgId = Just messageId
                        , inReplyTo = Nothing
                        , fields = Map.fromList fields_
                        }
                  }
          runtime.send message
          now <- runtime.getCurrentTime
          let later = addTimeMicros rPC_TIMEOUT_MICROS now
          let timerWheel' =
                insertTimer
                  later
                  (Just messageId, failure)
                  eventLoopState.timerWheel
          handleEffects
            effects
            eventLoopState
              { rpcs = Map.insert messageId success eventLoopState.rpcs
              , nextMessageId = messageId + 1
              , timerWheel = timerWheel'
              }
        DELIVER_VAR varId output -> do
          eventLoopState' <- case lookupDelete varId eventLoopState.awaits of
            Nothing ->
              return
                eventLoopState {vars = Map.insert varId output eventLoopState.vars}
            Just ((nodeContext, continuation), awaits') -> do
              let (nodeState', effects') =
                    execNode
                      (continuation output)
                      nodeContext
                      eventLoopState.nodeState
              handleEffects
                effects'
                eventLoopState {nodeState = nodeState', awaits = awaits'}
          handleEffects
            effects
            eventLoopState'
        AWAIT_VAR varId mMessage continuation -> do
          eventLoopState' <-
            case lookupDelete varId eventLoopState.vars of
              -- Sometimes a var could be delivered before we await for it.
              Just (output, vars') -> do
                now <- runtime.getCurrentTime
                let (prng', prng'') = splitPrng eventLoopState.prng
                let (nodeState', effects') =
                      execNode
                        (continuation output)
                        (NodeContext mMessage now prng')
                        eventLoopState.nodeState
                handleEffects
                  effects'
                  eventLoopState
                    { vars = vars'
                    , nodeState = nodeState'
                    , prng = prng''
                    }
              Nothing -> do
                -- XXX: Doesn't make sense to save the time here...
                now <- runtime.getCurrentTime
                let (prng', prng'') = splitPrng eventLoopState.prng
                return
                  eventLoopState
                    { awaits =
                        Map.insert
                          varId
                          (NodeContext mMessage now prng', continuation)
                          eventLoopState.awaits
                    , prng = prng''
                    }
          handleEffects
            effects
            eventLoopState'

consoleEventLoop ::
  (input -> Node state input output)
  -> state
  -> ValidateMarshal input output
  -> IO ()
consoleEventLoop node initialState validateMarshal = do
  args <- getArgs
  seed <- case readMaybe =<< safeHead args of
    Nothing -> randomIO
    Just seed -> return seed
  runtime <- consoleRuntime jsonCodec
  eventLoop node initialState (mkPrng seed) validateMarshal runtime

tcpEventLoop ::
  (input -> Node state input output)
  -> state
  -> Seed
  -> ValidateMarshal input output
  -> Int
  -> IO ()
tcpEventLoop node initialState seed validateMarshal port = do
  runtime <- tcpRuntime port noNeighbours jsonCodec
  eventLoop node initialState (mkPrng seed) validateMarshal runtime
    `finally` runtime.shutdown
