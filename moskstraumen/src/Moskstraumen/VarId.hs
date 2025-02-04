module Moskstraumen.VarId (module Moskstraumen.VarId) where

import Moskstraumen.Prelude

------------------------------------------------------------------------

newtype VarId = VarId Word64
  deriving newtype (Eq, Ord, Show, Num)
