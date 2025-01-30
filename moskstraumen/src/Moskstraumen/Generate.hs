module Moskstraumen.Generate (module Moskstraumen.Generate) where

import Moskstraumen.Prelude
import Moskstraumen.Random

------------------------------------------------------------------------

type Size = Word32

newtype Generate a = Generate (Prng -> Size -> a)
  deriving (Functor)

word8 :: Generate Word8
word8 = undefined
