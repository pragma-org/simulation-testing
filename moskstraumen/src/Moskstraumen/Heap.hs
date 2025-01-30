module Moskstraumen.Heap (module Moskstraumen.Heap) where

import qualified Data.Heap as Heap

------------------------------------------------------------------------

newtype Heap time a = Heap (Heap.Heap (Heap.Entry time a))

empty :: Heap time a
empty = Heap Heap.empty
