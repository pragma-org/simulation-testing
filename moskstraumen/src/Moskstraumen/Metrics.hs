module Moskstraumen.Metrics (module Moskstraumen.Metrics) where

import Moskstraumen.Prelude

------------------------------------------------------------------------

data Metrics = Metrics
  { droppedMessages :: Word64
  , partitions :: Word64
  , numberOfTests :: Word64
  }
  deriving stock (Eq, Show)

emptyMetrics :: Metrics
emptyMetrics =
  Metrics
    { droppedMessages = 0
    , partitions = 0
    , numberOfTests = 0
    }

instance Semigroup Metrics where
  Metrics dm1 p1 not1 <> Metrics dm2 p2 not2 = Metrics (dm1 + dm2) (p1 + p2) (not1 + not2)

instance Monoid Metrics where
  mempty = emptyMetrics
  mappend = (<>)

displayMetrics :: Metrics -> Text
displayMetrics = textShow
