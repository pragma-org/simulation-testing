module Moskstraumen.Time (module Moskstraumen.Time) where

import Data.IORef
import Data.Time
import Data.Time.Calendar.OrdinalDate (fromOrdinalDate)

import Moskstraumen.Prelude

------------------------------------------------------------------------

newtype FakeTime = FakeTime (IORef UTCTime)

newFakeTime :: IO FakeTime
newFakeTime = FakeTime <$> newIORef epoch

getFakeTime :: FakeTime -> IO UTCTime
getFakeTime (FakeTime ref) = readIORef ref

setFakeTime :: FakeTime -> UTCTime -> IO ()
setFakeTime (FakeTime ref) = writeIORef ref

epoch :: UTCTime
epoch = UTCTime (fromOrdinalDate 1970 0) 0

addTimeMicros :: Int -> UTCTime -> UTCTime
addTimeMicros micros time = addUTCTime (realToFrac micros * 0.000001) time
