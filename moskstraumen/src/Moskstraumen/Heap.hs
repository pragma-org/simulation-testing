{-# LANGUAGE StandaloneDeriving #-}

module Moskstraumen.Heap (module Moskstraumen.Heap) where

import qualified Data.Foldable as Foldable
import qualified Data.Heap as Heap
import qualified Data.Set as Set

import Moskstraumen.Prelude

------------------------------------------------------------------------

newtype Heap time a = Heap (Heap.Heap (Heap.Entry time a))
  deriving newtype (Semigroup, Monoid, Show)

deriving instance Foldable (Heap time)

empty :: Heap time a
empty = Heap Heap.empty

pop :: Heap time a -> Maybe ((time, a), Heap time a)
pop (Heap heap) = case Heap.viewMin heap of
  Nothing -> Nothing
  Just (Heap.Entry time x, heap') -> Just ((time, x), Heap heap')

fromList :: (Ord time) => [(time, a)] -> Heap time a
fromList = Heap . Heap.fromList . map (uncurry Heap.Entry)

toList :: Heap time a -> [(time, a)]
toList (Heap entries) =
  map (\(Heap.Entry time x) -> (time, x)) (Foldable.toList entries)

-- Avoids duplicates.
union :: (Ord time, Ord a) => Heap time a -> Heap time a -> Heap time a
union h1 h2 =
  fromList
    ( Set.toList
        ( (Set.fromList (Moskstraumen.Heap.toList h1))
            `Set.union` (Set.fromList (Moskstraumen.Heap.toList h2))
        )
    )
