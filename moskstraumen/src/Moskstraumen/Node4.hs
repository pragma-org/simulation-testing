module Moskstraumen.Node4 (module Moskstraumen.Node4) where

import Control.Monad.RWS
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map

import Moskstraumen.EventLoop2
import Moskstraumen.FreeMonad
import Moskstraumen.Message
import Moskstraumen.NodeId
import Moskstraumen.Prelude
import Moskstraumen.Runtime2

------------------------------------------------------------------------

type Node state input output = Node' state input output ()

newtype Node' state input output a = Node (Free (NodeF state input output) a)

data NodeF state input output x
  = Send NodeId input x
  | Reply output x
  | RPC
      NodeId
      input
      (Node state input output)
      (output -> Node state input output)
      x
  | Log Text x
  | After Int (Node state input output) x
  deriving (Functor)

data NodeContext input output = NodeContext
  { incoming :: Maybe Message
  , validateMarshal :: ValidateMarshal input output
  }

data NodeState state = NodeState
  { self :: NodeId
  , neighbours :: [NodeId]
  , state :: state
  }

initialNodeState :: state -> NodeState state
initialNodeState initialState =
  NodeState
    { self = "uninitialised"
    , neighbours = []
    , state = initialState
    }

------------------------------------------------------------------------

execNode' ::
  Node state input output
  -> NodeContext input output
  -> NodeState state
  -> (NodeState state, [Effect output (Node state input output)])
execNode' node nodeContext nodeState =
  execRWS (runNode node) nodeContext nodeState

runNode ::
  Node state input output
  -> RWS
      (NodeContext input output)
      [Effect output (Node state input output)]
      (NodeState state)
      ()
runNode (Node node0) = iterM aux return node0
  where
    aux ::
      NodeF
        state
        input
        output
        ( RWS
            (NodeContext input output)
            [Effect output (Node state input output)]
            (NodeState state)
            ()
        )
      -> RWS
          (NodeContext input output)
          [Effect output (Node state input output)]
          (NodeState state)
          ()
    aux (Send toNodeId input ih) = do
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
      ih
    aux (Reply output ih) = do
      nodeContext <- ask
      nodeState <- get
      case nodeContext.incoming of
        Nothing ->
          error
            "reply cannot be used in a context where there's \
            \ nothing to reply to, e.g. timers."
        Just message -> do
          let (kind_, fields_) = nodeContext.validateMarshal.marshalOutput output
          tell
            [ SEND
                ( Message
                    { src = nodeState.self
                    , dest = message.src
                    , body =
                        Payload
                          { kind = kind_
                          , msgId = message.body.msgId
                          , inReplyTo = message.body.msgId
                          , fields = Map.fromList fields_
                          }
                    }
                )
            ]
          ih
    aux (After micros node ih) = do
      nodeContext_ <- ask
      nodeState_ <- get
      tell
        [ SET_TIMER micros Nothing (snd (execNode' node nodeContext_ nodeState_))
        ]
      ih
    aux (RPC toNodeId input failure success ih) = do
      nodeContext <- ask
      nodeState <- get
      {-
      let messageId = nodeState.nextMessageId
      let (kind_, fields_) = nodeContext.validateMarshal.marshalInput input
      traceM "RPC: SEND"
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
      traceM "RPC: TIMER"
      tell [SET_TIMER rpcTimeoutMicros (Just messageId)]
      put
        nodeState
          { rpcs = Map.insert messageId success nodeState.rpcs
          , timers = Map.insert timerId failure nodeState.timers
          , nextMessageId = messageId + 1
          , nextTimerId = timerId + 1
          }
          -}
      ih

eventLoop ::
  (Monad m) =>
  (input -> Node state input output)
  -> state
  -> ValidateMarshal input output
  -> Runtime m
  -> m ()
eventLoop node initialState validateMarshal runtime =
  eventLoop_
    node
    execNode'
    ( \mMessage ->
        NodeContext
          { incoming = mMessage
          , validateMarshal = validateMarshal
          }
    )
    (initialNodeState initialState)
    -- XXX: dup, already in node context... Maybe all uses of validateMarshal
    -- should be moved to event loop?
    validateMarshal
    runtime
