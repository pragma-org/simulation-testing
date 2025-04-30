{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE Rank2Types #-}

module Moskstraumen.Experiment.SourceSinkNode3 (module Moskstraumen.Experiment.SourceSinkNode3) where

import Control.Concurrent (threadDelay)
import Data.Aeson (FromJSON, ToJSON)
import qualified Data.Aeson as Json
import qualified Data.ByteString.Char8 as BS8
import Data.ByteString.Lazy (ByteString)
import qualified Data.ByteString.Lazy as LBS
import qualified Data.ByteString.Lazy.Char8 as LBS8
import Data.List (delete, (\\))
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as Text
import Data.Typeable (Typeable, cast)
import Data.Void
import GHC.Generics (Rep)
import System.IO

import Moskstraumen.FreeMonad
import Moskstraumen.Message2
import Moskstraumen.NodeId
import Moskstraumen.Prelude

------------------------------------------------------------------------

type Node s k o a = Free (NodeF s k o) a

data NodeF s k o x
  = forall i. Await (k i) (i -> x)
  | Yield o (() -> x)
  | Get (s -> x)
  | Put s (() -> x)
  | forall a. LiftIO (IO a) (a -> x)
  | Stop
  | RPC NodeId Json.Value (RPCError -> x) (Json.Value -> x) (() -> x)

type RPCError = String

instance Functor (NodeF s i o) where
  fmap f (Await ki k) = Await ki (f . k)
  fmap f (Yield o k) = Yield o (f . k)
  fmap f (Get k) = Get (f . k)
  fmap f (Put s' k) = Put s' (f . k)
  fmap f (LiftIO io k) = LiftIO io (f . k)
  fmap _f Stop = Stop
  fmap f (RPC nodeId input failure success k) =
    RPC nodeId input (f . failure) (f . success) (f . k)

------------------------------------------------------------------------

data Is a b where
  Refl :: Is a a

await :: Node s (Is i) o i
await = awaits Refl

awaits :: k i -> Node s k o i
awaits ki = generic' (Await ki)

yield :: o -> Node s i o ()
yield o = generic' (Yield o)

get :: Node s i o s
get = generic' Get

put :: s -> Node s i o ()
put s' = generic' (Put s')

modify :: (s -> s) -> Node s i o ()
modify f = do
  s <- get
  put (f s)

liftIO :: IO a -> Node s i o a
liftIO io = generic' (LiftIO io)

stop :: Node s i o a
stop = Free Stop

rpc ::
  (ToJSON i, FromJSON o) =>
  NodeId
  -> i
  -> (RPCError -> Node s (Is i) o ())
  -> (o -> Node s (Is i) o ())
  -> Node s (Is i) o ()
rpc nodeId input failure success =
  generic'
    ( RPC
        nodeId
        (Json.toJSON input)
        failure
        ( \value -> case Json.fromJSON value of
            Json.Success o -> success o
            Json.Error err -> failure err
        )
    )

------------------------------------------------------------------------

type Source s o = forall k. Node s k o ()

stdinSource :: Source s String
stdinSource = do
  s <- liftIO (putStr "input> " >> getLine)
  if null s
    then stop
    else yield s

source :: (Foldable f) => f a -> Source s a
source = mapM_ yield

debugEnabled :: Bool
debugEnabled = False

debug :: BS8.ByteString -> Node s i o ()
debug bs
  | debugEnabled = liftIO $ BS8.hPutStrLn stderr bs
  | otherwise = return ()

stdinBS :: Source s ByteString
stdinBS = do
  debug "stdinBS: awaiting getline"
  bs <- liftIO BS8.getLine
  debug ("stdinBS: getLine: " <> bs)
  if BS8.null bs
    then do
      debug "stdinBS: stop"
      stop
    else do
      yield (LBS.fromStrict bs)

type Sink s k = Node s k Void ()

stdoutShow :: (Show a) => Sink s (Is a)
stdoutShow = do
  s <- await
  liftIO (print s)

stdoutBS :: Sink s (Is ByteString)
stdoutBS = do
  debug "stdoutBS: awaiting..."
  bs <- await
  debug $ "stdoutBS: got: " <> (LBS8.toStrict bs)
  liftIO (LBS8.hPutStrLn stdout bs)

------------------------------------------------------------------------

runNode :: Node s k o () -> NodeF s k o (Node s k o ())
runNode (Pure ()) = Stop
runNode (Free f) = f

------------------------------------------------------------------------

identity :: Node s (Is a) a ()
identity = do
  a <- await
  yield a

data NodeState s = NodeState
  { localState :: s
  , self :: NodeId
  , nextMessageId :: MessageId
  , pendingRPCs :: PendingRPCs
  }

type PendingRPCs =
  Map
    MessageId
    (Json.Value -> SomeNode (Is (Message Json.Value)) Json.Value ())

initialNodeState :: s -> NodeId -> NodeState s
initialNodeState s0 nodeId = NodeState s0 nodeId 0 Map.empty

infixr 1 >>>

(>>>) ::
  Node (NodeState s) (Is a) b ()
  -> Node (NodeState s) (Is b) c ()
  -> Node (NodeState s) (Is a) c ()
f >>> g = case runNode g of
  Stop -> stop
  Yield c k -> yield c >> (f >>> k ())
  Await Refl k -> case runNode f of
    Stop -> stop
    Yield b k' -> k' () >>> k b
    Await p k' -> do
      i <- awaits p
      k' i >>> g
    LiftIO io k' -> do
      x <- liftIO io
      k' x >>> (await >>= k)
    Get k' -> do
      s <- get
      k' s >>> g
    Put s' k' -> do
      put s'
      k' () >>> g
    RPC n v failure success k' -> do
      generic' (RPC n v (\e -> failure e >>> g) (\c -> success c >>> g))
      k' () >>> g
  LiftIO io k -> do
    x <- liftIO io
    f >>> k x
  Get k -> do
    s <- get
    f >>> k s
  Put s' k -> do
    put s'
    f >>> k ()
  RPC n i failure success k -> do
    generic' (RPC n i (\e -> f >>> failure e) (\c -> f >>> success c))
    f >>> k ()

-- XXX: Shared state doesn't make sense here?
(&&&) ::
  Node s (Is a) b () -> Node s (Is a) c () -> Node s (Is a) (b, c) ()
f &&& g = do
  i <- await
  s <- get
  (_s', bs) <- liftIO (run' f [i] s)
  (_s', cs) <- liftIO (run' g [i] s)
  zipWithM_ (\b c -> yield (b, c)) bs cs

(***) ::
  Node s (Is a) c () -> Node s (Is b) d () -> Node s (Is (a, b)) (c, d) ()
f *** g = do
  (a, b) <- await
  s <- get
  (_s', cs) <- liftIO (run' f [a] s)
  (_s', ds) <- liftIO (run' g [b] s)
  zipWithM_ (\c d -> yield (c, d)) cs ds

(|||) ::
  Node (NodeState s) (Is a) c ()
  -> Node (NodeState s) (Is b) c ()
  -> Node (NodeState s) (Is (Either a b)) c ()
f ||| g =
  await >>= \case
    Left a -> yield a >>> f
    Right b -> yield b >>> g

supply ::
  forall f s i o.
  (Foldable f) =>
  f i
  -> Node s (Is i) o ()
  -> Node s (Is i) o ()
supply = foldr go id
  where
    go ::
      i
      -> (Node s (Is i) o () -> Node s (Is i) o ())
      -> Node s (Is i) o ()
      -> Node s (Is i) o ()
    go i r n = case runNode n of
      Stop -> stop
      Await Refl k -> r (k i)
      Yield o k -> yield o >> go i r (k ())
      LiftIO io k -> liftIO io >>= \x -> go i r (k x)

run' :: Node s (Is i) o () -> [i] -> s -> IO (s, [o])
run' node is s = run (supply is node) s

run :: Node s k o () -> s -> IO (s, [o])
run n = go
  where
    go s = case runNode n of
      Stop -> return (s, [])
      Yield o k -> liftM (fmap (o :)) (run (k ()) s)
      Await _p _k -> return (s, [])
      LiftIO io k -> do
        x <- io
        run (k x) s
      Get k -> run (k s) s
      Put s' k -> run (k ()) s'
      RPC n v success failure k -> do
        undefined -- XXX: ?
        run (k ()) s

run_ :: (Show o) => Node s k o () -> s -> IO ()
run_ node s = void (run node s)

------------------------------------------------------------------------

test :: IO ()
test =
  run_
    (forever stdinSource >>> forever identity >>> forever stdoutShow)
    (initialNodeState () "test")

test2 :: IO ()
test2 = do
  run_
    ( source ["foo" :: String, "bar", "baz"]
        >>> forever identity
        >>> forever stdoutShow
    )
    (initialNodeState () "test2")
t :: IO ()
t = test2

------------------------------------------------------------------------

data Echo
  = Init {node_id :: NodeId, node_ids :: [NodeId]}
  | Echo {echo :: String}
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

data EchoOk
  = Init_Ok
  | Echo_Ok {echo :: String}
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

jsonDecode ::
  (Generic i, FromJSON i, Json.GFromJSON Json.Zero (Rep i)) =>
  Node s (Is ByteString) (Message i) ()
jsonDecode = do
  bs <- await
  case decodeMessage bs of
    Left err ->
      error
        ("Failed trying to parse: '" <> LBS8.unpack bs <> "'\nError: " <> err)
    Right msg -> yield msg

jsonEncode ::
  (Generic o, ToJSON o, Json.GToJSON' Json.Value Json.Zero (Rep o)) =>
  Node s (Is (Message o)) ByteString ()
jsonEncode = do
  o <- await
  yield (encodeMessage o)

reply ::
  Node (NodeState s) (Is (a, Message ())) (Message a) ()
reply = do
  (x, msg) <- await
  messageId <- nextMessageId <$> get
  modify
    (\ns -> ns {nextMessageId = messageId + 1})
  yield
    ( msg
        { src = msg.dest
        , dest = msg.src
        , msgId = Just messageId
        , inReplyTo = msg.msgId
        , body = x
        }
    )

auto :: (i -> o) -> Node s (Is i) o ()
auto f = do
  i <- await
  yield (f i)

echoNode :: Node s (Is Echo) EchoOk ()
echoNode = do
  await >>= \case
    Init {} -> yield Init_Ok
    Echo s -> yield (Echo_Ok s)

echo' :: Node (NodeState ()) (Is i) Void ()
echo' =
  forever stdinBS
    >>> forever jsonDecode
    >>> forever
      ((forever (auto body) >>> forever echoNode) &&& forever (auto void))
    >>> forever reply
    >>> forever jsonEncode
    >>> forever stdoutBS

libMain :: IO ()
libMain = do
  hSetBuffering stdin LineBuffering
  hSetBuffering stdout LineBuffering
  hSetBuffering stderr LineBuffering
  run_
    echo'
    (initialNodeState () "n1")

------------------------------------------------------------------------

bcast' ::
  Node
    (NodeState BroadcastState)
    (Is Broadcast)
    Void
    ()
bcast' =
  forever stdinBS
    >>> forever jsonDecode
    >>> forever handleRPC
    >>> forever
      (forever (forever bcast ||| forever identity) *** forever identity)
    >>> forever reply
    >>> forever jsonEncode
    >>> forever stdoutBS

data SomeNode k o a = forall s. (Typeable s) => SomeNode (Node s k o a)

handleRPC ::
  (FromJSON i, Typeable o, Typeable s) =>
  Node
    (NodeState s)
    (Is (Message Json.Value))
    (Either i o, Message ())
    ()
handleRPC = do
  pending <- pendingRPCs <$> get
  msg <- await
  case msg.inReplyTo >>= \k -> Map.lookup k pending of
    Just k -> case k msg.body of
      SomeNode node -> case cast node of
        Just node' -> node' >>> (await >>= (\o -> yield (Right o, void msg)))
        Nothing -> error "handleRPC: state type mismatch"
    Nothing -> case Json.fromJSON msg.body of
      Json.Success i -> yield (Left i, void msg)
      Json.Error e -> info (Text.pack e) >>> stop

data Broadcast
  = Broadcast Json.Value
  | Read
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

data BroadcastOk
  = Broadcast_Ok
  | Read_Ok [Json.Value]
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

data BroadcastState = BroadcastState
  { seen :: Set Json.Value
  , unAcked :: Map Json.Value [NodeId]
  }

initialState :: BroadcastState
initialState = BroadcastState Set.empty Map.empty

bcast :: Node (NodeState BroadcastState) (Is Broadcast) BroadcastOk ()
bcast =
  await >>= \case
    Broadcast msg -> do
      -- Acknowledge the request.
      yield Broadcast_Ok
      seenMessages <- seen . localState <$> get
      when (msg `Set.notMember` seenMessages) $ do
        modify
          ( \s ->
              s {localState = s.localState {seen = Set.insert msg s.localState.seen}}
          )
        neighbours <- getPeers
        sender <- getSender
        modify
          ( \s ->
              s
                { localState =
                    s.localState
                      { unAcked = Map.insert msg (neighbours \\ [sender]) s.localState.unAcked
                      }
                }
          )
        let go = do
              unAckedNodes <- (Map.! msg) . unAcked . localState <$> get
              if null unAckedNodes
                then info ("Done with message: " <> fromString (show msg))
                else do
                  info
                    ( "Need to replicate \""
                        <> Text.pack (show msg)
                        <> "\" to "
                        <> Text.pack (show unAckedNodes)
                    )
                  forM_ unAckedNodes $ \nodeId -> rpc
                    nodeId
                    (Broadcast msg)
                    ( \e ->
                        info
                          ( "Failed to deliver "
                              <> fromString (show msg)
                              <> " to "
                              <> unNodeId nodeId
                              <> ": "
                              <> fromString e
                          )
                    )
                    $ \resp ->
                      case resp of
                        Broadcast_Ok -> do
                          info ("Got ack from: " <> unNodeId nodeId)
                          modify
                            ( \s ->
                                s
                                  { localState =
                                      s.localState
                                        { unAcked = Map.adjust (delete nodeId) msg s.localState.unAcked
                                        }
                                  }
                            )
                        _otherwise -> error "broadcast: unexpected response"
                  sleep 1_000_000
                  go
        go
    Read -> do
      seenMessages <- seen . localState <$> get
      info ("Read, seen: " <> fromString (show seenMessages))
      yield (Read_Ok (Set.toList seenMessages))

info :: Text -> Node s i o ()
info = liftIO . Text.putStrLn

sleep :: Int -> Node s i o ()
sleep = liftIO . threadDelay

getPeers :: Node (NodeState s) i o [NodeId]
getPeers = undefined

getSender = undefined
