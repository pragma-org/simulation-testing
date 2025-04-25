{-# LANGUAGE Rank2Types #-}

module Moskstraumen.Experiment.SourceSinkNode2 (module Moskstraumen.Experiment.SourceSinkNode2) where

import Data.Void

import Moskstraumen.FreeMonad
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
await = generic' (Await Refl)

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
  yield s

source :: (Foldable f) => f a -> Source () a
source = mapM_ yield

type Sink s k = Node s k Void ()

stdoutSink :: (Show a) => Sink s (Is a)
stdoutSink = do
  s <- await
  liftIO (print s)

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
(>>>) :: Node s (Is a) b () -> Node s (Is b) c () -> Node s (Is a) c ()
f >>> g = case runNode g of
  Stop -> stop
  Yield c k -> yield c >> (f >>> k ())
  Await Refl k -> case runNode f of
    Stop -> stop
    Yield b k' -> k' () >>> k b
    Await Refl k' -> do
      a <- await
      k' a >>> g
    LiftIO io k' -> do
      x <- liftIO io
      k' x >>> (await >>= k)
  LiftIO io k -> do
    x <- liftIO io
    f >>> k x
  Get k -> error "ge"
  Put s' k -> error "pu"

run :: Node s k o () -> s -> IO [o]
run n = go
  where
    go s = case runNode n of
      Stop -> return []
      Yield o k -> liftM (o :) (run (k ()) s)
      Await _p _k -> error "run: await"
      LiftIO io k -> do
        x <- io
        run (k x) s

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
