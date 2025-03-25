module Moskstraumen.Workload (module Moskstraumen.Workload) where

import Moskstraumen.Generate
import Moskstraumen.LinearTemporalLogic
import Moskstraumen.Message
import Moskstraumen.Prelude

------------------------------------------------------------------------

-- start snippet Workload

data Property
  = LTL (Form Message)
  | TracePredicate ([Message] -> PropertyResult)

data PropertyResult = Pass | Fail String

(===) :: (Show a, Eq a) => a -> a -> PropertyResult
x === y = if x == y then Pass else Fail (show x <> " /= " <> show y)

data Workload = Workload
  { name :: Text
  , generate :: Gen [Message]
  , property :: Property
  }

-- end snippet
