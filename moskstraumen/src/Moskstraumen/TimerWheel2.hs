module Moskstraumen.TimerWheel2 (module Moskstraumen.TimerWheel2) where

import Data.List (sortBy)
import Data.Ord (comparing)

import Moskstraumen.Prelude

------------------------------------------------------------------------

-- XXX: Use a heap instead.
newtype TimerWheel time a = TimerWheel [(time, a)]
  deriving (Show)

emptyTimerWheel :: TimerWheel time a
emptyTimerWheel = TimerWheel []

insertTimer ::
  (Ord time) => time -> a -> TimerWheel time a -> TimerWheel time a
insertTimer time x (TimerWheel agenda) =
  TimerWheel (sortBy (comparing fst) ((time, x) : agenda))

filterTimer :: (a -> Bool) -> TimerWheel time a -> TimerWheel time a
filterTimer p (TimerWheel agenda) =
  TimerWheel (filter (p . snd) agenda)

popTimer :: TimerWheel time a -> Maybe ((time, a), TimerWheel time a)
popTimer (TimerWheel []) = Nothing
popTimer (TimerWheel (next : agenda)) = Just (next, TimerWheel agenda)
