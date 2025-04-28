{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE Rank2Types #-}

module Moskstraumen.Experiment.SourceSinkNode2 (module Moskstraumen.Experiment.SourceSinkNode2) where

import Data.Aeson (FromJSON, ToJSON)
import qualified Data.Aeson as Json
import qualified Data.ByteString.Char8 as BS8
import Data.ByteString.Lazy (ByteString)
import qualified Data.ByteString.Lazy as LBS
import qualified Data.ByteString.Lazy.Char8 as LBS8
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

instance Functor (NodeF s i o) where
  fmap f (Await ki k) = Await ki (f . k)
  fmap f (Yield o k) = Yield o (f . k)
  fmap f (Get k) = Get (f . k)
  fmap f (Put s' k) = Put s' (f . k)
  fmap f (LiftIO io k) = LiftIO io (f . k)
  fmap _f Stop = Stop

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

liftIO :: IO a -> Node s i o a
liftIO io = generic' (LiftIO io)

stop :: Node s i o a
stop = Free Stop

------------------------------------------------------------------------

type Source s o = forall k. Node s k o ()

stdinSource :: Source () String
stdinSource = do
  s <- liftIO (putStr "input> " >> getLine)
  if null s
    then stop
    else yield s

source :: (Foldable f) => f a -> Source () a
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

infixr 1 >>>

(>>>) :: Node s k b () -> Node s (Is b) c () -> Node s k c ()
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
  LiftIO io k -> do
    x <- liftIO io
    f >>> k x
  Get k -> do
    s <- get
    f >>> k s
  Put s' k -> do
    put s'
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

-- XXX: run . supply?
run' :: Node s (Is i) o () -> [i] -> s -> IO (s, [o])
run' node [] s = run node s
run' node (i : is) s = case runNode node of
  Stop -> return (s, [])
  Yield o k -> liftM (fmap (o :)) (run' (k ()) (i : is) s)
  Await Refl k -> run' (k i) is s
  LiftIO io k -> do
    x <- io
    run' (k x) (i : is) s
  Get k -> run' (k s) (i : is) s
  Put s' k -> run' (k ()) (i : is) s'

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

run_ :: (Show o) => Node s k o () -> s -> IO ()
run_ node s = do
  (_s', _os) <- run node s
  -- hPutStrLn stderr ("run_: one step complete: " <> show os)
  -- run_ node s'
  return ()

------------------------------------------------------------------------

test :: IO ()
test =
  run_
    (forever stdinSource >>> forever identity >>> forever stdoutShow)
    ()

test2 :: IO ()
test2 = do
  run_
    ( source ["foo" :: String, "bar", "baz"]
        >>> forever identity
        >>> forever stdoutShow
    )
    ()

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

reply :: Node MessageId (Is (a, Message ())) (Message a) ()
reply = do
  (x, msg) <- await
  nextMessageId <- get
  put (nextMessageId + 1)
  yield
    ( msg
        { src = msg.dest
        , dest = msg.src
        , msgId = Just nextMessageId
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

echo' :: Node MessageId k Void ()
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
  run_ echo' 0

-- {"id":0,"src":"c0","dest":"n1","body":{"type":"init","node_id":"n1","node_ids":["n1"],"msg_id":1}}
--
-- {"id":94,"src":"c2","dest":"n1","body":{"echo":"Please echo 16","type":"echo","msg_id":47}}
