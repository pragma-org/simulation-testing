module Moskstraumen.EventLoop2 (module Moskstraumen.EventLoop2) where

import Control.Exception (finally)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Time
import Debug.Trace

import Moskstraumen.Codec
import Moskstraumen.Effect
import Moskstraumen.Message
import Moskstraumen.Node4
import Moskstraumen.NodeId
import Moskstraumen.Parse
import Moskstraumen.Prelude
import Moskstraumen.Runtime.TCP
import Moskstraumen.Runtime2
import Moskstraumen.TimerWheel2
import Moskstraumen.VarId

------------------------------------------------------------------------

rPC_TIMEOUT_MICROS :: Int
rPC_TIMEOUT_MICROS = 1_000_000 -- 1 second.

------------------------------------------------------------------------

data EventLoopState state input output = EventLoopState
  { rpcs :: Map MessageId (output -> Node state input output)
  , nodeState :: NodeState state
  , nextMessageId :: MessageId
  , timerWheel ::
      TimerWheel UTCTime (Maybe MessageId, Node state input output)
  , vars :: Map VarId output
  , awaits :: Map VarId (NodeContext, output -> Node state input output)
  }

initialEventLoopState ::
  NodeState state -> EventLoopState state input output
initialEventLoopState initialNodeState =
  EventLoopState
    { rpcs = Map.empty
    , nodeState = initialNodeState
    , nextMessageId = 0
    , timerWheel = emptyTimerWheel
    , vars = Map.empty
    , awaits = Map.empty
    }

------------------------------------------------------------------------

eventLoop ::
  forall m state input output.
  (Monad m) =>
  (input -> Node state input output)
  -> state
  -> ValidateMarshal input output
  -> Runtime m
  -> m ()
eventLoop node initialState validateMarshal runtime =
  loop (initialEventLoopState (initialNodeState initialState))
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
          let nanos = realToFrac (diffUTCTime time now)
              micros = round (nanos * 1_000_000)
          -- traceM ("timer will trigger in: " <> show micros <> " µs")
          runtime.timeout micros runtime.receive >>= \case
            Nothing -> do
              -- The next timer triggered, which means we should run the
              -- effects associated with that timer. Futhermore, if
              -- there's a messageId associated with the timer, it means
              -- that an RPC call timed out and we should remove the
              -- successful continuation from from eventLoopState.rpcs.
              -- traceM ("timer triggered")
              --
              let (nodeState', effects) =
                    execNode
                      timeoutNode
                      (NodeContext Nothing)
                      eventLoopState.nodeState
              let eventLoopState' = eventLoopState {nodeState = nodeState', timerWheel = timerWheel'}
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
      [Message]
      -> EventLoopState state input output
      -> m (EventLoopState state input output)
    handleMessages [] eventLoopState = return eventLoopState
    handleMessages (message : messages) eventLoopState =
      case message.body.inReplyTo of
        Nothing -> case runParser validateMarshal.validateInput message of
          Nothing -> error ("eventLoop, failed to parse input: " ++ show message)
          Just input -> do
            let (nodeState', effects) =
                  execNode
                    (node input)
                    (NodeContext (Just message))
                    eventLoopState.nodeState
            eventLoopState' <-
              handleEffects
                effects
                eventLoopState {nodeState = nodeState'}
            handleMessages messages eventLoopState'
        Just inReplyToMessageId ->
          case runParser validateMarshal.validateOutput message of
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
                  let (nodeState', effects) =
                        execNode
                          (success output)
                          (NodeContext (Just message))
                          eventLoopState.nodeState
                  eventLoopState' <-
                    handleEffects
                      effects
                      eventLoopState {nodeState = nodeState', rpcs = rpcs'}

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
                  , arrivalTime = Nothing
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
          let (kind_, fields_) = validateMarshal.marshalOutput output
          let message =
                Message
                  { src = srcNodeId
                  , dest = destNodeId
                  , arrivalTime = Nothing
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
          let later =
                addUTCTime
                  (realToFrac (fromIntegral micros / 1_000_000))
                  now
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
                  , arrivalTime = Nothing
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
          let later =
                addUTCTime
                  (realToFrac (fromIntegral rPC_TIMEOUT_MICROS / 1_000_000))
                  now
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
                let (nodeState', effects') =
                      execNode
                        (continuation output)
                        (NodeContext mMessage)
                        eventLoopState.nodeState
                handleEffects
                  effects'
                  eventLoopState
                    { vars = vars'
                    , nodeState = nodeState'
                    }
              Nothing ->
                return
                  eventLoopState
                    { awaits =
                        Map.insert
                          varId
                          (NodeContext mMessage, continuation)
                          eventLoopState.awaits
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
  runtime <- consoleRuntime jsonCodec
  eventLoop node initialState validateMarshal runtime

tcpEventLoop ::
  (input -> Node state input output)
  -> state
  -> ValidateMarshal input output
  -> Int
  -> IO ()
tcpEventLoop node initialState validateMarshal port = do
  runtime <- tcpRuntime port jsonCodec
  eventLoop node initialState validateMarshal runtime
    `finally` runtime.shutdown
