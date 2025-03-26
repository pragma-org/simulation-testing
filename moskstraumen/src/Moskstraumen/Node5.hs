module Moskstraumen.Node5 (module Moskstraumen.Node5) where

import Control.Applicative
import Data.Aeson
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map

import Moskstraumen.FreeMonad
import Moskstraumen.NodeId
import Moskstraumen.Prelude
import Moskstraumen.Time
import Moskstraumen.VarId

------------------------------------------------------------------------

type Node s i o a = i -> NodeBody s i o a

type Node_ s i o = Node s i o ()

newtype NodeBody s i o a = NodeBody {unNodeBody :: Free (NodeF s i o) a}

data NodeF s i o x
  = Reply o (() -> x)
  | Send NodeId i (() -> x)
  | RPC NodeId i (RPCError -> x) (o -> x) ~x
  | Fail String
  | NewVar (VarId -> x)
  | forall v. DeliverVar VarId v x
  | forall v. AwaitVar VarId (v -> x)
  | TimerMicros Int (() -> x)

instance Functor (NodeF s i o) where
  fmap f (Reply o k) = Reply o (f . k)
  fmap f (Send nodeId i k) = Send nodeId i (f . k)
  fmap f (RPC nodeId i failure success x) = RPC nodeId i (f . failure) (f . success) (f x)
  fmap _f (Fail string) = Fail string
  fmap f (NewVar k) = NewVar (f . k)
  fmap f (DeliverVar varId var x) = DeliverVar varId var (f x)
  fmap f (AwaitVar varId k) = AwaitVar varId (f . k)
  fmap f (TimerMicros micros k) = TimerMicros micros (f . k)

data RPCError = E

instance Functor (NodeBody s i o) where
  fmap f (NodeBody m) = NodeBody (fmap f m)

instance Applicative (NodeBody s i o) where
  pure = NodeBody . Pure
  NodeBody mf <*> NodeBody mx = NodeBody (mf <*> mx)

instance MonadFail (NodeBody s i o) where
  fail = NodeBody . Free . Fail

instance Alternative (NodeBody s i o) where
  empty = fail "empty"
  NodeBody (Free (Fail _)) <|> n = n
  m <|> _n = m

instance MonadPlus (NodeBody s i o) where
  mzero = empty
  mplus = (<|>)

instance Monad (NodeBody s i o) where
  return = pure
  NodeBody m >>= k = NodeBody (m >>= unNodeBody . k)

generic ::
  ( (x -> Free f x)
    -> NodeF state input output (Free (NodeF state input output) a)
  )
  -> NodeBody state input output a
generic op = NodeBody (Free (op Pure))

generic_ ::
  ( Free f ()
    -> NodeF state input output (Free (NodeF state input output) a)
  )
  -> NodeBody state input output a
generic_ op = NodeBody (Free (op (Pure ())))

syncRPC ::
  NodeId
  -> i
  -> (RPCError -> NodeBody s i o ())
  -> NodeBody s i o (Either RPCError o)
syncRPC nodeId i failure = do
  varId <- generic NewVar
  generic_
    $ RPC
      nodeId
      i
      (unNodeBody . failure)
      (\o -> unNodeBody $ generic_ (DeliverVar varId o))
  generic (AwaitVar varId)

type MessageId = Word64

data Message a = Message
  { src :: NodeId
  , dest :: NodeId
  , msgId :: Maybe MessageId
  , inReplyTo :: Maybe MessageId
  , payload :: a
  }
  deriving stock (Functor, Foldable, Traversable)

data Runtime = Runtime
  { send :: [Message Value] -> IO ()
  , receive :: IO [(Time, Message Value)]
  -- , log :: Text -> m ()
  -- , timeout ::
  --     Microseconds
  --     -> m [(Time, Message)]
  --     -> m (Maybe [(Time, Message)])
  -- , getCurrentTime :: m Time
  -- , shutdown :: m ()
  }

data NodeState s i o = NodeState
  { localState :: s
  , rpcs :: Map MessageId (Message Value -> NodeBody s i o ())
  , nextMsgId :: MessageId
  , self :: NodeId
  , nextVarId :: VarId
  }

initialNodeState :: s -> NodeState s i o
initialNodeState s = NodeState s Map.empty 0 "uninitialised" 0

data Codec i o = Codec
  { decodeInput :: Value -> Either String i
  , encodeOutput :: o -> Value
  }

------------------------------------------------------------------------

runNode ::
  Node s i o a
  -> Codec i o
  -> NodeState s i o
  -> Message Value
  -> (NodeState s i o, [Message Value], a)
runNode node codec s mv = case mv.inReplyTo of
  Nothing -> case traverse codec.decodeInput mv of
    Right mi -> runNodeBody (void mv) (node mi.payload) codec s
    Left _ -> undefined
  Just msgId -> undefined

runNodeBody ::
  Message ()
  -> NodeBody s i o a
  -> Codec i o
  -> NodeState s i o
  -> (NodeState s i o, [Message Value], a)
runNodeBody mv (NodeBody m) codec s = iterM go done m (s, [])
  where
    done x (s, messages) = (s, reverse messages, x)

    go (Reply o k) (s, acc) = do
      let message =
            Message
              { src = mv.dest
              , dest = mv.src
              , msgId = undefined
              , inReplyTo = mv.msgId
              , payload = codec.encodeOutput o
              }
      k () (s, message : acc)
    go (NewVar k) (s, acc) = do
      let varId = s.nextVarId
      k varId (s {nextVarId = varId + 1}, acc)
    go (DeliverVar varId var x) acc = undefined
    go (AwaitVar varId k) acc = undefined

-- go (RPC)
-- \| RPC NodeId i (RPCError -> x) (o -> x) ~x

{-
runNodeBody (Pure ()) _codec _runtime _s _mi = return ()
runNodeBody (Free (Reply o k)) codec runtime s mi = do
  let mv = Message mi.dest mi.src mi.msgId (codec.encodeOutput o)
  runtime.send mv
  runNodeBody (k ()) codec runtime s mi
runNodeBody (Free (Send nid i k)) codec runtime s mi = do
  let m = Message undefined nid undefined
  runtime.send m
  runNodeBody (NodeBody (k ())) codec runtime s mi
runNodeBody (Free (RPC nid i failure success k)) codec runtime s mi = do
  runNodeBody (NodeBody (k ())) codec runtime s mi
 -}

------------------------------------------------------------------------

eventLoop :: Node_ s i o -> s -> Codec i o -> Runtime -> IO ()
eventLoop node initialState codec runtime =
  go (initialNodeState initialState)
  where
    go s = do
      incoming <- runtime.receive
      forM_ incoming $ \(time, message) -> do
        case runNode node codec s message of
          (s', outgoing, ()) -> do
            runtime.send outgoing
            go s'
