module Moskstraumen.EventLoop2 (module Moskstraumen.EventLoop2) where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Time

import Moskstraumen.Message
import Moskstraumen.Parse
import Moskstraumen.Prelude
import Moskstraumen.Pretty
import Moskstraumen.Runtime2
import Moskstraumen.TimerWheel (TimerId)

------------------------------------------------------------------------

data EventLoopState node nodeState output = EventLoopState
  { timers :: Map TimerId (node ())
  , rpcs :: Map MessageId (output -> node ())
  , vars :: Map VarId output
  , awaits :: Map VarId (output -> Some node)
  , nodeState :: nodeState
  , nextMessageId :: MessageId
  , nextTimerId :: TimerId
  , nextVarId :: VarId
  }

initialEventLoopState ::
  nodeState -> EventLoopState nodenode nodeState output
initialEventLoopState initialNodeState =
  EventLoopState
    { timers = Map.empty
    , rpcs = Map.empty
    , vars = Map.empty
    , awaits = Map.empty
    , nodeState = initialNodeState
    , nextMessageId = 0
    , nextTimerId = 0
    , nextVarId = 0
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

data Effect output x
  = SEND Message
  | LOG Text
  | SET_TIMER Microseconds (Maybe MessageId) [Effect output x]
  | DO_RPC MessageId (output -> x)

------------------------------------------------------------------------

eventLoop_ ::
  forall m input output node nodeState.
  (Monad m) =>
  (input -> node ())
  -> (node () -> nodeState -> (nodeState, [Effect output (node ())]))
  -> nodeState
  -> ValidateMarshal input output
  -> Runtime m
  -> m ()
eventLoop_ node runNode initialNodeState validateMarshal runtime =
  loop (initialEventLoopState initialNodeState)
  where
    loop :: EventLoopState node nodeState output -> m ()
    loop eventLoopState = do
      runtime.popTimer >>= \case
        Nothing -> do
          messages <- runtime.receive
          eventLoopState' <- handleMessages messages eventLoopState
          loop eventLoopState'
        Just (time, (mMessageId, effects)) -> do
          now <- runtime.getCurrentTime
          let nanos = realToFrac (diffUTCTime time now)
              micros = round (nanos * 1_000_000)
          runtime.timeout micros runtime.receive >>= \case
            Nothing -> do
              effects ()
              case mMessageId of
                Nothing -> loop eventLoopState
                -- The next timer triggered
                -- check if this timer has a messageId associated with it, if so
                -- an RPC timed out and we should remove it from
                -- eventLoopState.rpcs.
                Just messageId ->
                  loop eventLoopState {rpcs = Map.delete messageId eventLoopState.rpcs}
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
          Nothing -> undefined
          Just input -> do
            let (nodeState', effects) = runNode (node input) eventLoopState.nodeState
            eventLoopState' <-
              handleEffects effects eventLoopState {nodeState = nodeState'}
            handleMessages messages eventLoopState'
        Just inReplyToMessageId -> case runParser validateMarshal.validateOutput message of
          Nothing -> undefined
          Just output -> case lookupDelete inReplyToMessageId eventLoopState.rpcs of
            Nothing -> do
              -- Failure timer has triggered, and this rpc was removed from
              -- expected to be received.
              -- XXX: collect stats?
              return eventLoopState
            Just (success, rpcs') -> do
              let (nodeState', effects) = runNode (success output) eventLoopState.nodeState
              eventLoopState' <-
                handleEffects
                  effects
                  eventLoopState {nodeState = nodeState', rpcs = rpcs'}
              -- XXX: Remove timers associated with this message id
              -- deleteTimerByMessageId inReplyToMessageId
              return eventLoopState'

    handleEffects ::
      [Effect output (node ())]
      -> EventLoopState node nodeState output
      -> m (EventLoopState node nodeState output)
    handleEffects [] eventLoopState = return eventLoopState
    handleEffects (effect : effects) eventLoopState = do
      case effect of
        SEND message -> do
          runtime.send message
          handleEffects effects eventLoopState
        SET_TIMER micros mMessageId timeoutEffects -> do
          runtime.setTimer
            micros
            mMessageId
            -- NOTE: Thunk this, so that the effects don't happen yet.
            (\() -> handleEffects timeoutEffects eventLoopState >> return ())
          handleEffects effects eventLoopState
        LOG text -> do
          runtime.log text
          handleEffects effects eventLoopState
        DO_RPC messageId success -> do
          handleEffects
            effects
            eventLoopState
              { rpcs = Map.insert messageId success eventLoopState.rpcs
              }
