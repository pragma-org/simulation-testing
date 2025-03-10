module Moskstraumen.Workload (module Moskstraumen.Workload) where

import Moskstraumen.Generate
import Moskstraumen.LinearTemporalLogic
import Moskstraumen.Message
import Moskstraumen.Prelude

------------------------------------------------------------------------

-- start snippet Workload

data Property
  = LTL (Form Message)
  | TracePredicate ([Message] -> Bool)

data Workload = Workload
  { name :: Text
  , generate :: Gen [Message]
  , property :: Property
  }

-- end snippet
