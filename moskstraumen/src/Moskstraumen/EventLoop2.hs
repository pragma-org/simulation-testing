module Moskstraumen.EventLoop2 (module Moskstraumen.EventLoop2) where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Time
import Debug.Trace

import Moskstraumen.Codec
import Moskstraumen.Message
import Moskstraumen.NodeId
import Moskstraumen.Parse
import Moskstraumen.Prelude
import Moskstraumen.Pretty
import Moskstraumen.Runtime2
import Moskstraumen.TimerWheel2

------------------------------------------------------------------------

rPC_TIMEOUT_MICROS :: Int
rPC_TIMEOUT_MICROS = 1_000_000 -- 1 second.

------------------------------------------------------------------------

data EventLoopState node nodeState output = EventLoopState
  { rpcs :: Map MessageId (output -> node ())
  , nodeState :: nodeState
  , nextMessageId :: MessageId
  , timerWheel :: TimerWheel UTCTime (Maybe MessageId, node ())
  -- { timers :: Map TimerId (node ())
  -- , vars :: Map VarId output
  -- , awaits :: Map VarId (output -> Some node)
  -- , nextTimerId :: TimerId
  -- , nextVarId :: VarId
  }

initialEventLoopState ::
  nodeState -> EventLoopState nodenode nodeState output
initialEventLoopState initialNodeState =
  EventLoopState
    { rpcs = Map.empty
    , nodeState = initialNodeState
    , nextMessageId = 0
    , timerWheel = emptyTimerWheel
    -- , vars = Map.empty
    -- , awaits = Map.empty
    -- , timers = Map.empty
    -- , nextTimerId = 0
    -- , nextVarId = 0
    }

data Some f = forall a. Some (f a)

data ValidateMarshal input output = ValidateMarshal
  { validateInput :: Parser input
  , validateOutput :: Parser output
  , marshalInput :: Pretty input
  , marshalOutput :: Pretty output
  }

newtype VarId = VarId Word64
  deriving newtype (Eq, Ord, Num, Show)

-- Defunctionalise?
-- https://www.pathsensitive.com/2019/07/the-best-refactoring-youve-never-heard.html
data Effect node input output
  = SEND NodeId NodeId input
  | REPLY NodeId NodeId (Maybe MessageId) output
  | LOG Text
  | SET_TIMER Microseconds (Maybe MessageId) (node ())
  | DO_RPC NodeId NodeId input (node ()) (output -> node ())

------------------------------------------------------------------------

eventLoop_ ::
  forall m input output node nodeContext nodeState.
  (Monad m) =>
  (input -> node ())
  -> ( node ()
       -> nodeContext
       -> nodeState
       -> (nodeState, [Effect node input output])
     )
  -> (Maybe Message -> nodeContext)
  -> nodeState
  -> ValidateMarshal input output
  -> Runtime m
  -> m ()
eventLoop_ node runNode nodeContext initialNodeState validateMarshal runtime =
  loop (initialEventLoopState initialNodeState)
  where
    loop :: EventLoopState node nodeState output -> m ()
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
                    runNode
                      timeoutNode
                      (nodeContext Nothing)
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
      -> EventLoopState node nodeState output
      -> m (EventLoopState node nodeState output)
    handleMessages [] eventLoopState = return eventLoopState
    handleMessages (message : messages) eventLoopState =
      case message.body.inReplyTo of
        Nothing -> case runParser validateMarshal.validateInput message of
          Nothing -> error ("eventLoop, failed to parse input: " ++ show message)
          Just input -> do
            let (nodeState', effects) =
                  runNode
                    (node input)
                    (nodeContext (Just message))
                    eventLoopState.nodeState
            eventLoopState' <-
              handleEffects effects eventLoopState {nodeState = nodeState'}
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
                        runNode
                          (success output)
                          (nodeContext (Just message))
                          eventLoopState.nodeState
                  eventLoopState' <-
                    handleEffects
                      effects
                      eventLoopState {nodeState = nodeState', rpcs = rpcs'}
                  runtime.removeTimerByMessageId inReplyToMessageId
                  return eventLoopState'

    handleEffects ::
      [Effect node input output]
      -> EventLoopState node nodeState output
      -> m (EventLoopState node nodeState output)
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
          let (kind_, fields_) = validateMarshal.marshalOutput output
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
        SET_TIMER micros mMessageId timeoutEffects -> do
          runtime.setTimer
            micros
            mMessageId
            -- NOTE: Thunk this, so that the effects don't happen yet.
            ( \() -> do
                -- XXX: handleEffects timeoutEffects eventLoopState
                return ()
            )
          handleEffects effects eventLoopState
        LOG text -> do
          runtime.log text
          handleEffects effects eventLoopState
        DO_RPC srcNodeId destNodeId input failure success -> do
          traceM ("DO_RPC: " <> show srcNodeId <> " " <> show destNodeId)
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

consoleEventLoop_ ::
  (input -> node ())
  -> ( node ()
       -> nodeContext
       -> nodeState
       -> (nodeState, [Effect node input output])
     )
  -> (Maybe Message -> nodeContext)
  -> nodeState
  -> ValidateMarshal input output
  -> IO ()
consoleEventLoop_ node runNode nodeContext nodeState validateMarshal = do
  runtime <- consoleRuntime jsonCodec
  eventLoop_ node runNode nodeContext nodeState validateMarshal runtime
