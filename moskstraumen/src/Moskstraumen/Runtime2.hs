module Moskstraumen.Runtime2 (module Moskstraumen.Runtime2) where

import Data.Time

import Moskstraumen.Message
import Moskstraumen.NodeId
import Moskstraumen.Prelude

------------------------------------------------------------------------

type Microseconds = Int

data Runtime m = Runtime
  { receive :: m [Message]
  , log :: Text -> m ()
  , send :: Message -> m ()
  , timeout :: Microseconds -> m [Message] -> m (Maybe [Message])
  , setTimer :: Microseconds -> Maybe MessageId -> (() -> m ()) -> m ()
  , popTimer :: m (Maybe (UTCTime, (Maybe MessageId, () -> m ())))
  , getCurrentTime :: m UTCTime
  }

-- NOTE: `timeout 0` times out immediately while negative values
-- don't, hence the `max 0`.
