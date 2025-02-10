module Moskstraumen.FakeTime (module Moskstraumen.FakeTime) where

import Data.IORef

import Moskstraumen.Prelude
import Moskstraumen.Time

------------------------------------------------------------------------

newtype FakeTime = FakeTime (IORef Time)

newFakeTime :: IO FakeTime
newFakeTime = FakeTime <$> newIORef epoch

getFakeTime :: FakeTime -> IO Time
getFakeTime (FakeTime ref) = readIORef ref

setFakeTime :: FakeTime -> Time -> IO ()
setFakeTime (FakeTime ref) = writeIORef ref
