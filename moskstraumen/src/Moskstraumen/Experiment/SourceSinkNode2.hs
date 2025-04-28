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

stdinBS :: Source s ByteString
stdinBS = do
  bs <- liftIO BS8.getLine
  if BS8.null bs
    then stop
    else yield (LBS.fromStrict bs)

type Sink s k = Node s k Void ()

stdoutSink :: (Show a) => Sink s (Is a)
stdoutSink = do
  s <- await
  liftIO (print s)

stdoutBS :: Sink s (Is ByteString)
stdoutBS = do
  bs <- await
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
      Await _p _k -> error "run: await"
      LiftIO io k -> do
        x <- io
        run (k x) s
      Get k -> run (k s) s
      Put s' k -> run (k ()) s'

run_ :: Node s k o () -> s -> IO ()
run_ node s = do
  _ <- run node s
  return ()

------------------------------------------------------------------------

test :: IO ()
test =
  run_
    (forever stdinSource >>> forever identity >>> forever stdoutSink)
    ()

test2 :: IO ()
test2 = do
  run_
    ( source ["foo", "bar", "baz"] >>> forever identity >>> forever stdoutSink
    )
    ()

t :: IO ()
t = test2

------------------------------------------------------------------------

data Echo = Echo {echo :: String}
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

jsonDecode :: (FromJSON i) => Node s (Is ByteString) (Message i) ()
jsonDecode = do
  bs <- await
  case decodeMessage bs of
    Left err -> error err
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

echoNode :: Node s (Is Echo) Echo ()
echoNode = identity

echo' :: Node MessageId k Void ()
echo' =
  stdinBS
    >>> jsonDecode
    >>> ((auto body >>> echoNode) &&& auto void)
    >>> reply
    >>> jsonEncode
    >>> stdoutBS

libMain :: IO ()
libMain = run_ echo' 0
