module Moskstraumen.Node4 (module Moskstraumen.Node4) where

import Control.Monad.RWS
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map

import Moskstraumen.Codec
import Moskstraumen.EventLoop2
import Moskstraumen.FreeMonad
import Moskstraumen.Message
import Moskstraumen.NodeId
import Moskstraumen.Prelude
import Moskstraumen.Runtime2

------------------------------------------------------------------------

type Node state input output = Node' state input output ()

newtype Node' state input output a = Node (Free (NodeF state input output) a)
  deriving newtype (Functor, Applicative, Monad)

data NodeF state input output x
  = Send NodeId input x
  | Reply output x
  | RPC
      NodeId
      input
      -- NOTE: This needs to be lazy, or `rpcRetryForever` will loop with
      -- `StrictData`.
      ~(Node state input output)
      (output -> Node state input output)
      x
  | Log Text x
  | After Int (Node state input output) x
  | GetState (state -> x)
  | PutState state x
  | SetNodeId NodeId x
  | GetNodeId (NodeId -> x)
  | GetPeers ([NodeId] -> x)
  | SetPeers [NodeId] x
  | GetSender (NodeId -> x)
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

generic op = Node (Free (op Pure))
generic_ op = Node (Free (op (Pure ())))

send destNodeId input = generic_ (Send destNodeId input)

reply output = generic_ (Reply output)

rpc ::
  NodeId
  -> input
  -> Node state input output
  -> (output -> Node state input output)
  -> Node state input output
rpc destNodeId input failure success =
  generic_ (RPC destNodeId input failure success)

rpcRetryForever ::
  NodeId
  -> input
  -> (output -> Node state input output)
  -> Node state input output
rpcRetryForever nodeId input success = do
  rpc
    nodeId
    input
    ( info ("RPC to " <> unNodeId nodeId <> " timeout, retrying...")
        >> rpcRetryForever nodeId input success
    )
    success

info :: Text -> Node state input output
info text = generic_ (Log text)

getState :: Node' state input output state
getState = generic GetState

putState = generic_ . PutState

modifyState ::
  (state -> state) -> Node state input output
modifyState f = do
  s <- getState
  putState (f s)

getSender = generic GetSender

getPeers = generic GetPeers
setPeers = generic_ . SetPeers

getNodeId = generic GetNodeId
setNodeId = generic_ . SetNodeId

------------------------------------------------------------------------

execNode' ::
  Node state input output
  -> NodeContext input output
  -> NodeState state
  -> (NodeState state, [Effect (Node' state input output) input output])
execNode' node nodeContext nodeState =
  execRWS (runNode node) nodeContext nodeState

runNode ::
  Node state input output
  -> RWS
      (NodeContext input output)
      [Effect (Node' state input output) input output]
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
            [Effect (Node' state input output) input output]
            (NodeState state)
            ()
        )
      -> RWS
          (NodeContext input output)
          [Effect (Node' state input output) input output]
          (NodeState state)
          ()
    aux (Send toNodeId input ih) = do
      nodeContext <- ask
      nodeState <- get
      tell [SEND nodeState.self toNodeId input]
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
          tell [REPLY nodeState.self message.src message.body.msgId output]
          ih
    aux (After micros node ih) = do
      nodeContext_ <- ask
      nodeState_ <- get
      tell [SET_TIMER micros Nothing node]
      ih
    aux (RPC destNodeId input failure success ih) = do
      nodeContext <- ask
      nodeState <- get
      tell
        [ DO_RPC
            nodeState.self
            destNodeId
            input
            failure
            success
        ]
      ih
    aux (SetNodeId self_ ih) = do
      modify
        (\nodeState -> nodeState {self = self_})
      ih
    aux (GetNodeId ih) = do
      nodeState <- get
      ih nodeState.self
    aux (GetSender ih) = do
      nodeContext <- ask
      case nodeContext.incoming of
        Nothing -> error "getSender: used in context where there isn't one"
        Just message -> ih message.src
    aux (GetPeers ih) = do
      nodeState <- get
      ih nodeState.neighbours
    aux (SetPeers peers' ih) = do
      modify (\nodeState -> nodeState {neighbours = peers'})
      ih
    aux (GetState ih) = do
      nodeState <- get
      ih nodeState.state
    aux (PutState state' ih) = do
      modify (\nodeState -> nodeState {state = state'})
      ih
    aux (Log text ih) = do
      tell [LOG text]
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

consoleEventLoop ::
  (input -> Node state input output)
  -> state
  -> ValidateMarshal input output
  -> IO ()
consoleEventLoop node initialState validateMarshal = do
  runtime <- consoleRuntime jsonCodec
  eventLoop node initialState validateMarshal runtime
