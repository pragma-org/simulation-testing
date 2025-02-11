module Moskstraumen.Prelude (module X, Generic, Text, module Moskstraumen.Prelude, foldMapM) where

import Control.Exception (assert)
import Control.Monad as X
import Data.Foldable as X
import Data.Functor.Identity as X
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.String as X
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word as X
import GHC.Generics (Generic)
import Prelude as X hiding (log)

------------------------------------------------------------------------

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

lookupDelete :: (Ord k) => k -> Map k v -> Maybe (v, Map k v)
lookupDelete k m = case Map.lookup k m of
  Nothing -> Nothing
  Just v -> Just (v, Map.delete k m)

assertM :: (Monad m) => Bool -> m ()
assertM bool = assert bool (return ())

textShow :: (Show a) => a -> Text
textShow = Text.pack . show
