module Moskstraumen.Prelude (module X, Generic, Text, module Moskstraumen.Prelude, foldMapM) where

import Control.Monad as X
import Data.Foldable as X
import Data.Functor.Identity as X
import Data.String as X
import Data.Text (Text)
import GHC.Generics (Generic)
import Prelude as X

safeHead :: [a] -> Maybe a
safeHead [] = Nothing
safeHead (x : _xs) = Just x

foldMapM ::
  (Monoid b, Monad m, Foldable f) =>
  (a -> m b)
  -> f a
  -> m b
foldMapM f xs = foldl step return xs mempty
  where
    step r x z = f x >>= \y -> r $! z `mappend` y
{-# INLINE foldMapM #-}
