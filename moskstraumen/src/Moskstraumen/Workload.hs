module Moskstraumen.Workload (module Moskstraumen.Workload) where

import Moskstraumen.Generate
import Moskstraumen.LinearTemporalLogic
import Moskstraumen.Message
import Moskstraumen.Prelude

------------------------------------------------------------------------

-- start snippet Workload
data Workload = Workload
  { name :: Text
  , generate :: Gen [Message]
  , property :: Form Message
  }

-- end snippet
