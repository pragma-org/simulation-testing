{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}

module Moskstraumen.Node4 (module Moskstraumen.Node4) where

import Control.Monad.RWS.Strict

import Moskstraumen.Effect
import Moskstraumen.FreeMonad
import Moskstraumen.Message
import Moskstraumen.NodeId
import Moskstraumen.Prelude
import Moskstraumen.Random
import Moskstraumen.Time
import Moskstraumen.VarId

------------------------------------------------------------------------

type Node state input output = Node' state input output ()

newtype Node' state input output a
  = Node (Free (NodeF state input output) a)
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
  | Info Text x
  | After Int ~(Node state input output) x
  | GetState (state -> x)
  | PutState state x
  | SetNodeId NodeId x
  | GetNodeId (NodeId -> x)
  | GetPeers ([NodeId] -> x)
  | SetPeers [NodeId] x
  | GetSender (NodeId -> x)
  | Sleep Int ~(Node state input output)
  | NewVar (VarId -> x)
  | DeliverVar VarId output x
  | AwaitVar VarId (output -> x)
  | GetTime (Time -> x)
  | Random (Double -> x)
  deriving (Functor)

data NodeContext = NodeContext
  { incoming :: Maybe Message
  , time :: Time
  , prng :: Prng
  }

data NodeState state = NodeState
  { self :: NodeId
  , neighbours :: [NodeId]
  , state :: state
  , nextVarId :: VarId
  }

initialNodeState :: state -> NodeState state
initialNodeState initialState =
  NodeState
    { self = "uninitialised"
    , neighbours = []
    , state = initialState
    , nextVarId = 0
    }

------------------------------------------------------------------------

generic ::
  ( (x -> Free f x)
    -> NodeF state input output (Free (NodeF state input output) a)
  )
  -> Node' state input output a
generic op = Node (Free (op Pure))

generic_ ::
  ( Free f ()
    -> NodeF state input output (Free (NodeF state input output) a)
  )
  -> Node' state input output a
generic_ op = Node (Free (op (Pure ())))

send :: NodeId -> input -> Node state input output
send destNodeId input = generic_ (Send destNodeId input)

reply :: output -> Node state input output
reply output = generic_ (Reply output)

rpc ::
  NodeId
  -> input
  -> Node state input output
  -> (output -> Node state input output)
  -> Node state input output
rpc destNodeId input failure success =
  generic_ (RPC destNodeId input failure success)

brpc ::
  input
  -> Node state input output
  -> (output -> Node state input output)
  -> Node state input output
brpc input failure success = do
  self <- getNodeId
  neighbours <- getPeers
  forM_ (filter (/= self) neighbours) $ \destNodeId -> do
    rpc destNodeId input failure success

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
info text = generic_ (Info text)

instance MonadState state (Node' state input output) where
  get = generic GetState
  put = generic_ . PutState

getState :: Node' state input output state
getState = generic GetState

putState :: state -> Node state input output
putState = generic_ . PutState

modifyState ::
  (state -> state) -> Node state input output
modifyState f = do
  s <- getState
  putState (f s)

getSender :: Node' state input output NodeId
getSender = generic GetSender

getPeers :: Node' state input output [NodeId]
getPeers = generic GetPeers

setPeers :: [NodeId] -> Node state input output
setPeers = generic_ . SetPeers

getNodeId :: Node' state input output NodeId
getNodeId = generic GetNodeId

setNodeId :: NodeId -> Node' state input output ()
setNodeId = generic_ . SetNodeId

sleep :: Int -> Node state input output -> Node state input output
sleep micros node = Node (Free (Sleep micros node))

after :: Int -> Node state input output -> Node state input output
after micros task = Node (Free (After micros task (Pure ())))

every :: Int -> Node state input output -> Node state input output
every micros task = after micros (task >> every micros task)

newVar :: Node' state input output VarId
newVar = generic NewVar

deliverVar :: VarId -> a -> Node state input a
deliverVar varId output = generic_ (DeliverVar varId output)

awaitVar :: VarId -> Node' state input output output
awaitVar varId = generic (AwaitVar varId)

getTime :: Node' state input output Time
getTime = generic GetTime

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

random :: Node' state input output Double
random = generic Random

syncRpcRetry :: NodeId -> input -> Node' state input output output
syncRpcRetry _toNodeId _input = do
  undefined

{-
info "syncRpcRetry: start"
var <- newVar
rpcRetryForever toNodeId input $ \output -> do
  info "syncRpcRetry: success, deliever"
  deliverVar var output
-- let success = \output -> info "syncRpcRetry: deliever" >> deliverVar var output
-- rpc
--  toNodeId
--  input
--  (info "syncRpc: failed...")
--  success
info "syncRpcRetry: await..."
awaitVar var
 -}

------------------------------------------------------------------------

execNode ::
  Node state input output
  -> NodeContext
  -> NodeState state
  -> (NodeState state, [Effect (Node' state input output) input output])
execNode node nodeContext nodeState =
  execRWS (runNode node) nodeContext nodeState

runNode ::
  Node state input output
  -> RWS
      NodeContext
      [Effect (Node' state input output) input output]
      (NodeState state)
      ()
runNode (Node node0) = paraM aux return node0
  where
    aux ::
      NodeF
        state
        input
        output
        ( Free (NodeF state input output) ()
        , RWS
            NodeContext
            [Effect (Node' state input output) input output]
            (NodeState state)
            ()
        )
      -> RWS
          NodeContext
          [Effect (Node' state input output) input output]
          (NodeState state)
          ()
    aux (Send toNodeId input ih) = do
      nodeState <- get
      tell [SEND nodeState.self toNodeId input]
      snd ih
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
          snd ih
    aux (After micros node ih) = do
      tell [SET_TIMER micros Nothing node]
      snd ih
    aux (RPC destNodeId input failure success ih) = do
      nodeState <- get
      tell
        [ DO_RPC
            nodeState.self
            destNodeId
            input
            failure
            success
        ]
      snd ih
    aux (SetNodeId self_ ih) = do
      modify
        (\nodeState -> nodeState {self = self_})
      snd ih
    aux (GetNodeId ih) = do
      nodeState <- get
      snd (ih nodeState.self)
    aux (GetSender ih) = do
      nodeContext <- ask
      case nodeContext.incoming of
        Nothing -> error "getSender: used in context where there isn't one"
        Just message -> snd (ih message.src)
    aux (GetPeers ih) = do
      nodeState <- get
      snd (ih nodeState.neighbours)
    aux (SetPeers peers' ih) = do
      modify (\nodeState -> nodeState {neighbours = peers'})
      snd ih
    aux (GetState ih) = do
      nodeState <- get
      snd (ih nodeState.state)
    aux (PutState state' ih) = do
      modify (\nodeState -> nodeState {state = state'})
      snd ih
    aux (Info text ih) = do
      tell [LOG text]
      snd ih
    aux (Sleep micros node) = tell [SET_TIMER micros Nothing node]
    aux (NewVar ih) = do
      nodeState <- get
      let varId = nodeState.nextVarId
      put nodeState {nextVarId = varId + 1}
      snd (ih varId)
    aux (DeliverVar varId output ih) = do
      tell [DELIVER_VAR varId output]
      snd ih
    aux (AwaitVar varId ih) = do
      nodeContext <- ask
      tell [AWAIT_VAR varId nodeContext.incoming (Node . fst . ih)]
    aux (GetTime ih) = do
      nodeContext <- ask
      snd (ih nodeContext.time)
    aux (Random ih) = do
      nodeContext <- ask
      let (double, prng') = randomR (0, 1) nodeContext.prng
      local (\nodeContext -> nodeContext {prng = prng'}) (snd (ih double))
