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
  { rpcs :: Map MessageId (output -> node ())
  , nodeState :: nodeState
  -- { timers :: Map TimerId (node ())
  -- , vars :: Map VarId output
  -- , awaits :: Map VarId (output -> Some node)
  -- , nextMessageId :: MessageId
  -- , nextTimerId :: TimerId
  -- , nextVarId :: VarId
  }

initialEventLoopState ::
  nodeState -> EventLoopState nodenode nodeState output
initialEventLoopState initialNodeState =
  EventLoopState
    { rpcs = Map.empty
    , nodeState = initialNodeState
    -- , vars = Map.empty
    -- , awaits = Map.empty
    -- { timers = Map.empty
    -- , nextMessageId = 0
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

data Effect output x
  = SEND Message
  | LOG Text
  | SET_TIMER Microseconds (Maybe MessageId) [Effect output x]
  | DO_RPC MessageId (output -> x)

------------------------------------------------------------------------

eventLoop_ ::
  forall m input output node nodeContext nodeState.
  (Monad m) =>
  (input -> node ())
  -> ( node ()
       -> nodeContext
       -> nodeState
       -> (nodeState, [Effect output (node ())])
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
              -- The next timer triggered, which means we should run the
              -- effects associated with that timer. Futhermore, if
              -- there's a messageId associated with the timer, it means
              -- that an RPC call timed out and we should remove the
              -- successful continuation from from eventLoopState.rpcs.
              effects ()
              case mMessageId of
                Nothing -> loop eventLoopState
                Just messageId ->
                  loop
                    eventLoopState
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
                  -- XXX: Collect stats / log?
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
