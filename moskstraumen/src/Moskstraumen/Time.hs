module Moskstraumen.Time (module Moskstraumen.Time) where

import qualified Data.Text as Text
import Data.Time
import qualified Data.Time as Time
import Data.Time.Calendar.OrdinalDate (fromOrdinalDate)
import Data.Time.Format.ISO8601 (iso8601Show)

import Moskstraumen.Prelude

------------------------------------------------------------------------

newtype Time = Time UTCTime
  deriving newtype (Eq, Ord, Show)

getCurrentTime :: IO Time
getCurrentTime = Time <$> Time.getCurrentTime

epoch :: Time
epoch = Time (UTCTime (fromOrdinalDate 1970 0) 0)

addTimeMicros :: Int -> Time -> Time
addTimeMicros micros (Time time) =
  Time (addUTCTime (realToFrac micros * 0.000001) time)

-- diffTimeMicros t1 t2 = t1 - t2
diffTimeMicros :: Time -> Time -> Int
diffTimeMicros (Time t1) (Time t2) = micros
  where
    nanos = realToFrac (diffUTCTime t1 t2)
    micros = round (nanos * 1_000_000)

iso8601Format :: Time -> Text
iso8601Format (Time utcTime) = Text.pack (iso8601Show utcTime)
