module Moskstraumen.FreeMonad (module Moskstraumen.FreeMonad) where

import Moskstraumen.Prelude

------------------------------------------------------------------------

data Free f x
  = Pure x
  | Free (f (Free f x))

type Alg f x = f x -> x

generic' :: ((x -> Free f x) -> g (Free g y)) -> Free g y
generic' op = Free (op Pure)

iterM ::
  (Monad m, Functor f) =>
  Alg f (m a)
  -> (x -> m a)
  -> Free f x
  -> m a
iterM _f p (Pure x) = p x
iterM f p (Free op) = f (fmap (iterM f p) op)

paraM ::
  (Monad m, Functor f) =>
  (f (Free f x, m a) -> m a)
  -> (x -> m a)
  -> Free f x
  -> m a
paraM _f p (Pure x) = p x
paraM f p (Free op) = f (fmap (\x -> (x, paraM f p x)) op)

liftF :: (Functor f) => f x -> Free f x
liftF = Free . fmap Pure

------------------------------------------------------------------------

instance (Functor f) => Functor (Free f) where
  fmap = liftM

instance (Functor f) => Applicative (Free f) where
  pure = Pure
  (<*>) = ap

instance (Functor f) => Monad (Free f) where
  return = pure
  Pure x >>= k = k x
  Free m >>= k = Free (fmap (>>= k) m)

------------------------------------------------------------------------

-- https://hackage.haskell.org/package/kan-extensions
data Coyoneda f a where
  Coyoneda :: (b -> a) -> f b -> Coyoneda f a

instance Functor (Coyoneda f) where
  fmap f (Coyoneda g fb) = Coyoneda (f . g) fb

genericCoyoneda ::
  ((x -> Free f x) -> g (Free (Coyoneda g) y)) -> Free (Coyoneda g) y
genericCoyoneda op = Free (Coyoneda id (op Pure))

data OpF x = forall a. ExampleLiftIO (IO a) (a -> x)

type Op a = Free (Coyoneda OpF) a

coyonedaLiftIO :: IO a -> Op a
coyonedaLiftIO io = genericCoyoneda (ExampleLiftIO io)
