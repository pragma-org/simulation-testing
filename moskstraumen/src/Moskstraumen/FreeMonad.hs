module Moskstraumen.FreeMonad (module Moskstraumen.FreeMonad) where

import Moskstraumen.Prelude

------------------------------------------------------------------------

data Free f x
  = Pure x
  | Free (f (Free f x))

iterM ::
  (Monad m, Functor f) =>
  (f (m a) -> m a)
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
