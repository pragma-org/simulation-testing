{-# LANGUAGE QuantifiedConstraints #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE StandaloneDeriving #-}

module Moskstraumen.Experiment.AwaitNode (module Moskstraumen.Experiment.AwaitNode) where

import Control.Concurrent.STM
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Typeable

import Moskstraumen.FreeMonad
import Moskstraumen.Prelude

------------------------------------------------------------------------

data NodeF s k o x
  = forall i. (Typeable i) => Awaits (k i) (i -> x)
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
deriving instance Show (Tee l r x)
deriving instance Eq (Tee l r x)

awaits :: (Typeable i) => k i -> Node s k o i
awaits ki = generic' (Awaits ki)

yield :: o -> Node s k o ()
yield o = generic' (Yield o)

(<|>) :: Node s k o a -> Node s k o a -> Node s k o a
l <|> r = Free (l :<|> r)

get :: Node s k o s
get = generic' Get

runNode ::
  Node s k o ()
  -> s
  -> (forall i. (Typeable i) => k i -> STM i)
  -> STM (s, [o])
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

data IsTypeable a = (Typeable a) => IsTypeable a

data Runtime k o = Runtime
  { recv :: forall i. (Typeable i) => k i -> STM (IsTypeable i)
  , send :: o -> IO ()
  }

-- eventLoop :: Node s k o () -> s -> Runtime k o -> IO ()
-- eventLoop node s0 runtime = loop s0
--   where
--     loop s = do
--       (s', os) <- atomically (runNode node s (\ki -> recv runtime ki))
--       mapM_ runtime.send os
--       loop s'

testRuntime ::
  (Show o) =>
  (forall i. (Typeable i) => k i -> TBQueue i)
  -> IO (Runtime k o)
testRuntime fis = do
  return
    Runtime
      { recv = \ki -> IsTypeable <$> readTBQueue (fis ki)
      , send = print
      }

-- ------------------------------------------------------------------------
--
-- -- * Examples
--
-- exampleNode :: Node () (Tee Bool Char) String ()
-- exampleNode = do
--   bool <- awaits L
--   if bool
--     then do
--       char <- awaits R
--       yield [char]
--     else yield "false"
--
-- -- >>> test
-- -- "a"
-- test :: IO ()
-- test = do
--   lq <- queueFromList [True]
--   rq <- queueFromList ['a']
--   let fis :: Tee Bool Char i -> TBQueue i
--       fis = \case
--         L -> lq
--         R -> rq
--   rt <- testRuntime fis
--   eventLoop exampleNode () rt
--
-- priorityExampleNode :: Node () (Tee () ()) String ()
-- priorityExampleNode = do
--   e <- (Left <$> awaits L) <|> (Right <$> awaits R)
--   case e of
--     Left _ -> yield "left"
--     Right _ -> yield "right"
--
-- -- >>> testPriority
-- -- "left"
-- -- "left"
-- -- "right"
-- testPriority :: IO ()
-- testPriority = do
--   lq <- queueFromList [(), ()]
--   rq <- queueFromList [()]
--   let fis :: Tee () () i -> TBQueue i
--       fis = \case
--         L -> lq
--         R -> rq
--   rt <- testRuntime fis
--   eventLoop priorityExampleNode () rt

queueFromList :: [a] -> IO (TBQueue a)
queueFromList xs = do
  q <- newTBQueueIO (fromIntegral (length xs))
  mapM_ (atomically . writeTBQueue q) xs
  return q

------------------------------------------------------------------------

-- * Composition

-- data Is a b where
--   Refl :: Is a a
--
-- (>>>) ::
--   Node s (Is i) j () -> Node t (Is j) k () -> IO (Node (s, t) (Is i) k ())
-- f >>> g = do
--   (s, t) <- return get
--   (s', js) <- atomically (runNode f s undefined)
--   undefined
--

------------------------------------------------------------------------

data Effect k
  = forall i. (Typeable i) => Read Word (k i)
  | OrElse (Effect k) (Effect k)

data Input = forall i. (Typeable i) => Input Word i

data NodeState s k o = NodeState
  { localState :: s
  , waitingFor :: Map Word (Cont (Node s k o ()))
  , nextTicket :: Word
  }

data Cont x = forall i. (Typeable i) => Cont (i -> x)

runNode2 ::
  forall s k o.
  Node s k o ()
  -> NodeState s k o
  -> (NodeState s k o, [o], [Effect k])
runNode2 node s0 = go node s0 [] []

runNode2' ::
  forall s k o.
  (forall i. Eq (k i)) =>
  Input
  -> NodeState s k o
  -> (NodeState s k o, [o], [Effect k])
runNode2' (Input ticket i) s0 = case Map.lookup ticket s0.waitingFor of
  Nothing -> undefined
  Just (Cont k) -> case cast i of
    Just i' -> go (k i') s0 [] []

data Result s k o
  = Done
  | Awaiting

go ::
  Node s k o ()
  -> NodeState s k o
  -> [o]
  -> [Effect k]
  -> (NodeState s k o, [o], [Effect k])
go (Pure ()) s acc effs = (s, reverse acc, reverse effs)
go (Free (Awaits ki k)) s acc effs =
  let ticket = s.nextTicket
  in  ( s
          { waitingFor = Map.insert ticket (Cont k) s.waitingFor
          , nextTicket = ticket + 1
          }
      , reverse acc
      , reverse (Read ticket ki : effs)
      )
go (Free (Yield o k)) s acc effs = go (k ()) s (o : acc) effs
go (Free (l :<|> r)) s acc effs = undefined -- go l s acc `orElse` go r s acc

-- go (Free (Get k)) s acc = go (k s) s acc
-- go (Free (Put s' k)) _s acc = go (k ()) s' acc
--
eventLoop2 ::
  (forall i. (Eq (k i))) => Node s k o () -> s -> Runtime k o -> IO ()
eventLoop2 node s0 runtime = loop (NodeState s0 Map.empty 0)
  where
    loop s = do
      let (s', os, effs) = runNode2 node s
      mapM_ runtime.send os
      s'' <- handleEffects effs s' runtime
      loop s''

handleEffects ::
  (forall i. Eq (k i)) =>
  [Effect k]
  -> NodeState s k o
  -> Runtime k o
  -> IO (NodeState s k o)
handleEffects effs0 s0 runtime = go effs0 s0
  where
    go [] s = return s
    go (Read ticket ki : effs) s = do
      -- putStrLn $ "[debug] read: " ++ show ki
      IsTypeable i <- atomically (recv runtime ki)
      let (s', os, effs') = runNode2' (Input ticket i) s
      mapM_ runtime.send os
      s'' <- handleEffects effs' s' runtime
      go effs s''

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
  eventLoop2 exampleNode () rt
