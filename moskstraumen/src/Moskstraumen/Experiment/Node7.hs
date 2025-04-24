module Moskstraumen.Experiment.Node7 (module Moskstraumen.Experiment.Node7) where

import Control.Applicative
import Data.Aeson
import qualified Data.Aeson as Json
import qualified Data.ByteString.Char8 as BS8
import qualified Data.ByteString.Lazy.Char8 as LBS8
import Data.Either
import Data.Map.Strict (Map)
import System.IO
import System.Process

import Moskstraumen.FreeMonad
import Moskstraumen.NodeHandle (NodeHandle (..), close, handle)
import Moskstraumen.NodeId
import Moskstraumen.Prelude
import Moskstraumen.Simulate
import Moskstraumen.Time

------------------------------------------------------------------------

-- start snippet Node

newtype Node s i o = Node {unNode :: i -> NodeBody s i o ()}

newtype NodeBody s i o a = NodeBody {unNodeBody :: Free (NodeF s i o) a}

-- end snippet

-- start snippet NodeF
data NodeF s i o x
  = Reply o (() -> x)
  | Get (s -> x)
  | Put s (() -> x)

-- end snippet

instance Functor (NodeF s i o) where
  fmap f (Reply o k) = Reply o (f . k)
  fmap f (Get k) = Get (f . k)
  fmap f (Put s' k) = Put s' (f . k)

instance Functor (NodeBody s i o) where
  fmap f (NodeBody m) = NodeBody (fmap f m)

instance Applicative (NodeBody s i o) where
  pure = NodeBody . Pure
  NodeBody mf <*> NodeBody mx = NodeBody (mf <*> mx)

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

------------------------------------------------------------------------

-- start snippet echo
data Echo = Echo String
  deriving stock (Generic, Show)
  deriving anyclass (FromJSON, ToJSON)

echo :: Node () Echo Echo
echo = Node $ \input -> let output = input in reply output

echo' :: Node () Value Value
echo' = jsonCodec echo

jsonCodec ::
  (FromJSON i, ToJSON o) => Node s i o -> Node s Value Value
jsonCodec node = jsonDecode >>> node >>> jsonEncode
  where
    jsonDecode :: (FromJSON i) => Node s Value i
    jsonDecode = Node $ \value -> case Json.fromJSON value of
      Json.Error err -> error err
      Json.Success echoMsg -> reply echoMsg

    jsonEncode :: (ToJSON o) => Node s o Value
    jsonEncode = Node $ \o -> reply (Json.toJSON o)

reply :: o -> NodeBody s i o ()
reply output = NodeBody (Free (Reply output Pure))

-- end snippet

get :: NodeBody s i o s
get = NodeBody (Free (Get Pure))

put :: s -> NodeBody s i o ()
put s' = NodeBody (Free (Put s' Pure))

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
  { rsend :: Message Value -> IO ()
  , receive :: IO (Time, Message Value)
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
data NodeState s = NodeState
  { localState :: s
  , self :: NodeId
  }

-- end snippet
-- , rpcs :: Map MessageId (Message Value -> NodeBody s i o ())
-- , nextVarId :: VarId

-- start snippet initialNodeState
initialNodeState :: NodeId -> s -> NodeState s
initialNodeState nodeId s =
  NodeState
    { localState = s
    , self = nodeId
    }

-- end snippet

--    , nextVarId = 0
--    , rpcs = Map.empty

-- start snippet Codec
data Codec i o = Codec
  { decodeInput :: Value -> Either String i
  , encodeOutput :: o -> Value
  , encodeInput :: i -> Value
  }

-- end snippet

------------------------------------------------------------------------

-- start snippet runNode
runNode :: Node s i o -> i -> NodeState s -> (NodeState s, [o])
runNode node i s = fst (runNodeBody (unNode node i) s)

-- end snippet

-- runNode node codec s mv = case mv.inReplyTo of
--   Nothing -> case traverse codec.decodeInput mv of
--     Right mi -> runNodeBody (void mv) (node mi.payload) codec s
--     Left _ -> undefined
--   Just msgId -> undefined

-- start snippet runNodeBody
runNodeBody ::
  NodeBody s i o a -> NodeState s -> ((NodeState s, [o]), a)
runNodeBody (NodeBody m) s0 = iterM go done m (s0, [])
  where
    done x (s, messages) = ((s, reverse messages), x)

    go (Reply o k) (s, acc) =
      k () (s, o : acc)
    go (Get k) (s, acc) =
      k s.localState (s, acc)
    go (Put s' k) (s, acc) =
      k () (s {localState = s'}, acc)

-- end snippet
--    go (NewVar k) (s, acc) = do
--      let varId = s.nextVarId
--      k varId (s {nextVarId = varId + 1}, acc)

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
--
infixr 1 >>>
(>>>) :: Node s a b -> Node s b c -> Node s a c
f >>> g = Node $ \a -> do
  s <- get
  case runNode f a (NodeState {localState = s, self = "uninitialised"}) of
    (s', bs) -> do
      case go bs s' [] of
        (s'', cs) -> do
          mapM_ reply cs
          put s''.localState
  where
    go [] s acc = (s, reverse (concat acc))
    go (b : bs) s acc =
      case runNode g b s of
        (s', cs) -> go bs s' (cs : acc)

------------------------------------------------------------------------

testNode ::
  Node s i o -> s -> [i] -> [[o]]
testNode node initialState = go [] (initialNodeState "testNode" initialState)
  where
    go acc _s [] = reverse acc
    go acc s (i : is) = case runNode node i s of
      (s', os) -> go (os : acc) s' is

-- start snippet eventLoop

data EventLoopState = EventLoopState
  {nextMessageId :: MessageId}

initialEventLoopState :: EventLoopState
initialEventLoopState = EventLoopState {nextMessageId = 0}

eventLoop ::
  Node s Value Value -> NodeId -> s -> Runtime -> IO ()
eventLoop node nodeId initialState runtime =
  go (initialNodeState nodeId initialState) initialEventLoopState
  where
    go nodeState eventLoopState = do
      (_time, message) <- runtime.receive
      let messageId = eventLoopState.nextMessageId
      case runNode node message.payload nodeState of
        (nodeState', outgoing) -> do
          let nextMessageId' = messageId + fromIntegral (length outgoing)
          let outgoing' =
                zipWith
                  (makeMessage message)
                  [messageId .. nextMessageId']
                  outgoing
          mapM_ runtime.rsend outgoing'
          go nodeState' eventLoopState {nextMessageId = nextMessageId'}

makeMessage :: Message a -> MessageId -> Value -> Message Value
makeMessage incoming nextMessageId oValue =
  Message
    { src = incoming.dest
    , dest = incoming.src
    , msgId = Just nextMessageId
    , inReplyTo = incoming.msgId
    , payload = oValue
    }

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
      , rsend = consoleSend
      }
  where
    consoleReceive :: IO (Time, Message Value)
    consoleReceive = do
      line <- BS8.hGetLine stdin
      if BS8.null line
        then error "consoleReceive: empty line"
        else do
          BS8.hPutStrLn stderr ("consoleRuntime: recieved: " <> line)
          case Json.eitherDecodeStrict line of
            Right message -> do
              now <- getCurrentTime
              return (now, message)
            Left err ->
              error
                $ "consoleRuntime: failed to decode message: "
                ++ show err
                ++ "\nline: "
                ++ show line

    consoleSend :: Message Value -> IO ()
    consoleSend message = do
      BS8.hPutStrLn
        stderr
        ("consoleRuntime: sent: " <> LBS8.toStrict (Json.encode message))
      BS8.hPutStrLn stdout (LBS8.toStrict (Json.encode message))

-- end snippet

echoCodec :: Codec String String
echoCodec =
  Codec
    { decodeInput = \value -> case Json.fromJSON value of
        Json.Success input -> Right input
        Json.Error err -> Left err
    , encodeOutput = Json.toJSON
    , encodeInput = Json.toJSON
    }

-- start snippet testMain
testMain :: IO ()
testMain = eventLoop echo' "echo" () =<< consoleRuntime

-- end snippet

type Port = Int

-- start snippet prodMain
tcpRuntime :: Port -> Map NodeId Port -> IO Runtime
-- end snippet
tcpRuntime = undefined

-- start snippet prodMain

prodMain :: Port -> Map NodeId Port -> IO ()
prodMain port peers = eventLoop echo' "echo" () =<< tcpRuntime port peers

-- end snippet

-- start snippet pipeNodeHandle
pipeNodeHandle :: FilePath -> [String] -> IO NodeHandle
pipeNodeHandle fp args = do
  (Just hin, Just hout, _, processHandle) <-
    createProcess
      (proc fp args) {std_in = CreatePipe, std_out = CreatePipe}
  return
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

-- end snippet

-- start snippet simulatorMain
simulatorMain :: IO Bool
simulatorMain = blackboxTest "/path/to/test-main-binary" workload
  where
    -- end snippet

    workload = undefined
