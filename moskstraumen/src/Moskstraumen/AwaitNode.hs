{-# LANGUAGE Rank2Types #-}

module Moskstraumen.AwaitNode (module Moskstraumen.AwaitNode) where

import Control.Concurrent.STM

import Moskstraumen.FreeMonad
import Moskstraumen.Prelude

------------------------------------------------------------------------

data NodeF s k o x
  = forall i. Awaits (k i) (i -> x)
  | Yield o (() -> x)
  | (:<|>) ~x ~x
  | Get (s -> x)
  | Put s (() -> x)

instance Functor (NodeF s k o) where
  fmap f (Awaits ki k) = Awaits ki (f . k)
  fmap f (Yield o k) = Yield o (f . k)
  fmap f (l :<|> r) = f l :<|> f r
  fmap f (Get k) = Get (f . k)
  fmap f (Put s k) = Put s (f . k)

type Node s k o = Free (NodeF s k o)

data Tee l r x where
  L :: Tee l r l
  R :: Tee l r r

awaits :: k i -> Node s k o i
awaits ki = generic' (Awaits ki)

yield :: o -> Node s k o ()
yield o = generic' (Yield o)

(<|>) :: Node s k o a -> Node s k o a -> Node s k o a
l <|> r = Free (l :<|> r)

runNode ::
  Node s k o () -> s -> (forall i. k i -> STM i) -> STM (s, [o])
runNode node s0 recvs = go node s0 []
  where
    go (Pure ()) s acc = return (s, reverse acc)
    go (Free (Awaits ki k)) s acc = do
      i <- recvs ki
      go (k i) s acc
    go (Free (Yield o k)) s acc = go (k ()) s (o : acc)
    go (Free (l :<|> r)) s acc = go l s acc `orElse` go r s acc
    go (Free (Get k)) s acc = go (k s) s acc
    go (Free (Put s' k)) _s acc = go (k ()) s' acc

data Runtime k o = Runtime
  { recv :: forall i. k i -> STM i
  , send :: o -> IO ()
  }

eventLoop :: Node s k o () -> s -> Runtime k o -> IO ()
eventLoop node s0 runtime = loop s0
  where
    loop s = do
      (s', os) <- atomically (runNode node s (\ki -> recv runtime ki))
      mapM_ runtime.send os
      loop s'

testRuntime ::
  (Show o) =>
  (forall i. k i -> TBQueue i)
  -> IO (Runtime k o)
testRuntime fis = do
  return
    Runtime
      { recv = \ki -> readTBQueue (fis ki)
      , send = print
      }

------------------------------------------------------------------------

-- * Examples

exampleNode :: Node () (Tee Bool Char) String ()
exampleNode = do
  bool <- awaits L
  if bool
    then do
      char <- awaits R
      yield [char]
    else yield "false"

-- >>> test
-- "a"
test :: IO ()
test = do
  lq <- queueFromList [True]
  rq <- queueFromList ['a']
  let fis :: Tee Bool Char i -> TBQueue i
      fis = \case
        L -> lq
        R -> rq
  rt <- testRuntime fis
  eventLoop exampleNode () rt

priorityExampleNode :: Node () (Tee () ()) String ()
priorityExampleNode = do
  e <- (Left <$> awaits L) <|> (Right <$> awaits R)
  case e of
    Left _ -> yield "left"
    Right _ -> yield "right"

-- >>> testPriority
-- "left"
-- "left"
-- "right"
testPriority :: IO ()
testPriority = do
  lq <- queueFromList [(), ()]
  rq <- queueFromList [()]
  let fis :: Tee () () i -> TBQueue i
      fis = \case
        L -> lq
        R -> rq
  rt <- testRuntime fis
  eventLoop priorityExampleNode () rt

queueFromList :: [a] -> IO (TBQueue a)
queueFromList xs = do
  q <- newTBQueueIO (fromIntegral (length xs))
  mapM_ (atomically . writeTBQueue q) xs
  return q
