{-# LANGUAGE Rank2Types #-}

module Moskstraumen.Experiment.AwaitNode3 (module Moskstraumen.Experiment.AwaitNode3) where

import Control.Concurrent.STM
import Data.Char (toUpper)
import Debug.Trace

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

get :: Node s k o s
get = generic' Get

put :: s -> Node s k o ()
put s' = generic' (Put s')

data Runtime k o = Runtime
  { recv :: forall i. k i -> STM i
  , send :: o -> IO ()
  }

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

queueFromList :: [a] -> IO (TBQueue a)
queueFromList xs = do
  q <- newTBQueueIO (fromIntegral (length xs))
  mapM_ (atomically . writeTBQueue q) xs
  return q

------------------------------------------------------------------------

data NodeState s = NodeState
  { localState :: s
  }

data Result s k o
  = Done (NodeState s) [o]
  | Awaiting [(NodeState s, Cont k (Node s k o ()))] [o]

data Cont k x = forall i. Cont (k i) (i -> x)

runNode ::
  forall s k o.
  Node s k o ()
  -> NodeState s
  -> Result s k o
runNode node s0 = go node s0 []
  where
    go ::
      Node s k o ()
      -> NodeState s
      -> [o]
      -> Result s k o
    go (Pure ()) s acc = Done s (reverse acc)
    go (Free (Awaits ki k)) s acc = Awaiting [(s, Cont ki k)] (reverse acc)
    go (Free (Yield o k)) s acc = go (k ()) s (o : acc)
    go (Free (l :<|> r)) s acc = case go l s acc of
      done@Done {} -> done
      Awaiting awaiting os -> case go r s acc of
        done'@Done {} -> done'
        Awaiting awaiting' os' -> Awaiting (awaiting ++ awaiting') (os ++ os')
    go (Free (Get k)) s acc = go (k s.localState) s acc
    go (Free (Put s' k)) _s acc = go (k ()) (NodeState s') acc

eventLoop :: Node s k o () -> s -> Runtime k o -> IO ()
eventLoop node0 s0 runtime = loop node0 (NodeState s0)
  where
    loop node s = do
      case runNode node s of
        Done s' os -> do
          mapM_ runtime.send os
          loop node0 s'
        Awaiting conts os -> do
          mapM_ runtime.send os
          (s', node') <- recvs runtime conts
          loop node' s'

recvs ::
  forall s k o.
  Runtime k o
  -> [(NodeState s, Cont k (Node s k o ()))]
  -> IO (NodeState s, Node s k o ())
recvs runtime = atomically . go
  where
    go ::
      [(NodeState s, Cont k (Node s k o ()))]
      -> STM (NodeState s, Node s k o ())
    go [] = error ""
    go [(s, Cont ki k)] = do
      i <- recv runtime ki
      return (s, k i)
    go ((s, Cont ki k) : conts) =
      ( do
          i <- recv runtime ki
          return (s, k i)
      )
        `orElse` go conts

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

------------------------------------------------------------------------

-- * Composition

data Is a b where
  Refl :: Is a a

(>>>) ::
  (Show i, Show j, Show k) =>
  Node s (Is i) j ()
  -> Node t (Is j) k ()
  -> Node (s, t) (Is i) k ()
f >>> g = do
  (s, t) <- get
  case runNode f (NodeState s) of
    Done (NodeState s') js@[j] -> do
      -- traceM $ "done, js: " <> show js
      put (s', t)
      case runNode g (NodeState t) of
        Done (NodeState t') ks -> do
          put (s', t')
          mapM_ yield ks
        Awaiting [(t', Cont Refl k)] ks' -> do
          f >>> k j

    -- case runNode' g js t [] of
    --   (t', ks) -> do
    --     traceM ("ks: " <> show ks)
    --     put (s', t')
    --     mapM_ yield ks
    Awaiting [(NodeState s', Cont Refl k)] js' -> do
      put (s', t)
      i <- awaits Refl
      -- traceM ("awaits i: " <> show i)
      -- traceM ("yield js: " <> show js')
      (mapM_ yield js' >> k i) >>> g

echo :: Int -> Node () (Is String) String ()
echo i = do
  -- traceM $ "echo: " <> show i
  s <- awaits Refl
  -- traceM $ "echo, got: " <> show i <> " " <> s
  yield s

upper :: Int -> Node () (Is String) String ()
upper i = do
  -- traceM $ "upper: " <> show i
  s <- awaits Refl
  -- traceM $ "upper, got: " <> show i <> " " <> s
  yield (map toUpper s)

dup :: Node () (Is a) a ()
dup = do
  x <- awaits Refl
  yield x
  yield x

-- >>> testCompose
-- "FOO"
-- "FOO"
-- "BAR"
-- "BAR"
testCompose :: IO ()
testCompose = do
  q <- queueFromList ["foo", "bar" :: String]
  let fis :: Is String i -> TBQueue i
      fis Refl = q
  rt <- testRuntime fis
  eventLoop (upper 1 >>> echo 2 >>> dup) (((), ()), ()) rt

t :: IO ()
t = testCompose
