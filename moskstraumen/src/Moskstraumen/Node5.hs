module Moskstraumen.Node5 (module Moskstraumen.Node5) where

import Control.Applicative
import Data.Aeson
import qualified Data.Aeson as Json
import qualified Data.ByteString.Char8 as BS8
import qualified Data.ByteString.Lazy.Char8 as LBS8
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import System.IO
import System.Process

import Moskstraumen.FreeMonad
import Moskstraumen.NodeHandle (NodeHandle (..), close, handle)
import Moskstraumen.NodeId
import Moskstraumen.Prelude
import Moskstraumen.Time
import Moskstraumen.VarId

------------------------------------------------------------------------

type Node_ s i o = Node s i o ()

-- start snippet Node

type Node s i o a = i -> NodeBody s i o a

newtype NodeBody s i o a = NodeBody {unNodeBody :: Free (NodeF s i o) a}

-- end snippet

-- start snippet NodeF
data NodeF s i o x
  = Reply o (() -> x)
  | Get (s -> x)
  | Put s (() -> x)
  | Send NodeId i (() -> x)
  | -- end snippet
    RPC NodeId i (RPCError -> x) (o -> x) ~x
  | Fail String
  | NewVar (VarId -> x)
  | forall v. DeliverVar VarId v x
  | forall v. AwaitVar VarId (v -> x)
  | After Int x (() -> x)
  | At Time x (() -> x)

instance Functor (NodeF s i o) where
  fmap f (Reply o k) = Reply o (f . k)
  fmap f (Send nodeId i k) = Send nodeId i (f . k)
  fmap f (RPC nodeId i failure success x) = RPC nodeId i (f . failure) (f . success) (f x)
  fmap _f (Fail string) = Fail string
  fmap f (NewVar k) = NewVar (f . k)
  fmap f (DeliverVar varId var x) = DeliverVar varId var (f x)
  fmap f (AwaitVar varId k) = AwaitVar varId (f . k)
  fmap f (After micros k) = After micros (f . k)

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

------------------------------------------------------------------------

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

------------------------------------------------------------------------

-- start snippet echo
echo :: Node state String String ()
echo input = let output = input in NodeBody (Free (Reply output Pure))

-- end snippet

------------------------------------------------------------------------

-- start snippet Message
data Message a = Message
  { src :: NodeId
  , dest :: NodeId
  , msgId :: Maybe MessageId
  , inReplyTo :: Maybe MessageId
  , payload :: a
  }
  deriving stock (Generic, Functor, Foldable, Traversable)
  deriving anyclass (FromJSON, ToJSON)

type MessageId = Word64

-- end snippet

-- start snippet Runtime
data Runtime = Runtime
  { send :: [Message Value] -> IO ()
  , receive :: IO [(Time, Message Value)]
  }

-- end snippet
-- , log :: Text -> m ()
-- , timeout ::
--     Microseconds
--     -> m [(Time, Message)]
--     -> m (Maybe [(Time, Message)])
-- , getCurrentTime :: m Time
-- , shutdown :: m ()

-- start snippet NodeState
data NodeState s i o = NodeState
  { localState :: s
  , nextMessageId :: MessageId
  , self :: NodeId
  }

-- end snippet
-- , rpcs :: Map MessageId (Message Value -> NodeBody s i o ())
-- , nextVarId :: VarId

-- start snippet initialNodeState
initialNodeState :: s -> NodeState s i o
initialNodeState s =
  NodeState
    { localState = s
    , rpcs = Map.empty
    , nextMessageId = 0
    , self = "uninitialised"
    , nextVarId = 0
    }

-- end snippet

-- start snippet Codec
data Codec i o = Codec
  { decodeInput :: Value -> Either String i
  , encodeOutput :: o -> Value
  , encodeInput :: i -> Value
  }

-- end snippet

------------------------------------------------------------------------

-- start snippet runNode
runNode ::
  Node s i o a
  -> Codec i o
  -> NodeState s i o
  -> Message Value
  -> Either String (NodeState s i o, [Message Value], a)
runNode node codec s mv = case traverse codec.decodeInput mv of
  Right mi -> Right (runNodeBody (void mv) (node mi.payload) codec s)
  Left err -> Left err

-- end snippet

-- runNode node codec s mv = case mv.inReplyTo of
--   Nothing -> case traverse codec.decodeInput mv of
--     Right mi -> runNodeBody (void mv) (node mi.payload) codec s
--     Left _ -> undefined
--   Just msgId -> undefined

-- start snippet runNodeBody
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
      let messageId = s.nextMessageId
      let message =
            Message
              { src = mv.dest
              , dest = mv.src
              , msgId = Just messageId
              , inReplyTo = mv.msgId
              , payload = codec.encodeOutput o
              }
      k () (s {nextMessageId = messageId + 1}, message : acc)
    go (Send nodeId i k) (s, acc) = do
      let messageId = s.nextMessageId
      let message =
            Message
              { src = s.self
              , dest = nodeId
              , msgId = Just messageId
              , inReplyTo = Nothing
              , payload = codec.encodeInput i
              }
      k () (s {nextMessageId = messageId + 1}, message : acc)
    go (Get k) (s, acc) =
      k s.localState (s, acc)
    go (Put s' k) (s, acc) =
      k () (s {localState = s'}, acc)
    -- end snippet
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

-- start snippet eventLoop
eventLoop :: Node_ s i o -> s -> Codec i o -> Runtime -> IO ()
eventLoop node initialState codec runtime =
  go (initialNodeState initialState)
  where
    go s = do
      incoming <- runtime.receive
      forM_ incoming $ \(_time, message) -> do
        case runNode node codec s message of
          Left err -> do
            putStrLn ("Failed to parse input: " <> err)
            go s
          Right (s', outgoing, ()) -> do
            runtime.send outgoing
            go s'

-- end snippet

-- start snippet consoleRuntime
consoleRuntime :: IO Runtime
consoleRuntime = do
  hSetBuffering stdin LineBuffering
  hSetBuffering stdout LineBuffering
  hSetBuffering stderr LineBuffering
  return
    Runtime
      { receive = consoleReceive
      , send = consoleSend
      }
  where
    consoleReceive :: IO [(Time, Message Value)]
    consoleReceive = do
      line <- BS8.hGetLine stdin
      if BS8.null line
        then return []
        else do
          BS8.hPutStrLn stderr ("consoleRuntime: recieved: " <> line)
          case Json.eitherDecodeStrict line of
            Right message -> do
              now <- getCurrentTime
              return [(now, message)]
            Left err ->
              error
                $ "consoleRuntime: failed to decode message: "
                ++ show err
                ++ "\nline: "
                ++ show line

    consoleSend :: [Message Value] -> IO ()
    consoleSend messages =
      forM_ messages $ \message -> do
        BS8.hPutStrLn
          stderr
          ("consoleRuntime: sent: " <> LBS8.toStrict (Json.encode message))
        BS8.hPutStrLn stdout (LBS8.toStrict (Json.encode message))

-- end snippet

-- start snippet pipeNodeHandle
pipeNodeHandle :: Handle -> Handle -> ProcessHandle -> NodeHandle
pipeNodeHandle hin hout processHandle =
  NodeHandle
    { handle = \_arrivalTime message -> do
        LBS8.hPutStr hin (Json.encode message)
        BS8.hPutStr hin "\n"
        hFlush hin
        line <- BS8.hGetLine hout
        case Json.eitherDecodeStrict line of
          Left err -> hPutStrLn stderr err >> return []
          Right msg' -> return [msg']
    , close = terminateProcess processHandle
    }

pipeSpawn :: FilePath -> [String] -> IO NodeHandle
pipeSpawn fp args = do
  (Just hin, Just hout, _, processHandle) <-
    createProcess
      (proc fp args) {std_in = CreatePipe, std_out = CreatePipe}
  return (pipeNodeHandle hin hout processHandle)

-- end snippet
