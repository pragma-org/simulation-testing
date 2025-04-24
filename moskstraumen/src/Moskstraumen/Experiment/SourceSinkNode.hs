module Moskstraumen.Experiment.SourceSinkNode (module Moskstraumen.Experiment.SourceSinkNode) where

import Data.Void
import Moskstraumen.FreeMonad
import Moskstraumen.Prelude

------------------------------------------------------------------------

type Node s i o a = Free (NodeF s i o) a

data NodeF s i o x
  = Await (i -> x)
  | Yield o (() -> x)
  | Get (s -> x)
  | Put s (() -> x)
  | forall a. LiftIO (IO a) (a -> x)

instance Functor (NodeF s i o) where
  fmap f (Await k) = Await (f . k)
  fmap f (Yield o k) = Yield o (f . k)
  fmap f (Get k) = Get (f . k)
  fmap f (Put s' k) = Put s' (f . k)
  fmap f (LiftIO io k) = LiftIO io (f . k)

------------------------------------------------------------------------

await :: Node s i o i
await = generic' Await

yield :: o -> Node s i o ()
yield o = generic' (Yield o)

get :: Node s i o s
get = generic' Get

put :: s -> Node s i o ()
put s' = generic' (Put s')

liftIO :: IO a -> Node s i o a
liftIO io = generic' (LiftIO io)

------------------------------------------------------------------------

type Source s o = Node s () o ()

stdinSource :: Source () String
stdinSource = do
  s <- liftIO (putStr "input> " >> getLine)
  yield s

source :: (Foldable f) => f a -> Source () a
source = mapM_ yield

type Sink s i = Node s i Void ()

stdoutSink :: (Show a) => Sink () a
stdoutSink = do
  s <- await
  liftIO (print s)

------------------------------------------------------------------------

runNode :: forall s i o. Node s i o () -> i -> s -> IO (s, [o])
runNode node i s0 = iterM go done node (s0, [])
  where
    done () (s, messages) = return (s, reverse messages)

    go :: Alg (NodeF s i o) ((s, [o]) -> IO (s, [o]))
    go (Await k) (s, acc) = k i (s, acc)
    go (Yield o k) (s, acc) = k () (s, o : acc)
    go (Get k) (s, acc) = k s (s, acc)
    go (Put s' k) (_s, acc) = k () (s', acc)
    go (LiftIO io k) (s, acc) = do
      x <- io
      k x (s, acc)

------------------------------------------------------------------------

identity :: Node s a a ()
identity = do
  a <- await
  yield a

infixr 1 >>>
(>>>) :: Node s a b () -> Node s b c () -> Node s a c ()
f >>> g = do
  a <- await
  s <- get
  (s', bs) <- liftIO (runNode f a s)
  go s' bs
  where
    go s [] = put s
    go s (b : bs) = do
      (s', cs) <- liftIO (runNode g b s)
      mapM_ yield cs
      go s' bs

------------------------------------------------------------------------

testNode :: Node s () Void () -> s -> IO ()
testNode node = go
  where
    go s = do
      (_s', _os) <- runNode node () s
      return ()

eventLoop :: Node s () Void () -> s -> IO ()
eventLoop node = go
  where
    go s = do
      (s', _os) <- runNode node () s
      go s'

test :: IO ()
test =
  eventLoop (stdinSource >>> identity >>> stdoutSink) ()

test2 :: IO ()
test2 =
  testNode
    (source ["foo", "bar", "baz"] >>> identity >>> stdoutSink)
    ()
