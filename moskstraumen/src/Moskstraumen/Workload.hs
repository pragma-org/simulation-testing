module Moskstraumen.Workload (module Moskstraumen.Workload) where

import Moskstraumen.Generate
import Moskstraumen.LinearTemporalLogic
import Moskstraumen.Message
import Moskstraumen.Prelude

------------------------------------------------------------------------

data Workload = Workload
  { name :: Text
  , generateMessage :: Gen Message
  , property :: Form Message
  }
