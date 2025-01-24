module Moskstraumen.TimerWheel (module Moskstraumen.TimerWheel) where

import Data.List (sort)

import Moskstraumen.Prelude

------------------------------------------------------------------------

-- XXX: Use a heap instead.
data TimerWheel time = TimerWheel [(time, TimerId)]

newtype TimerId = TimerId Word64
  deriving newtype (Eq, Ord, Num, Show)

newTimerWheel :: TimerWheel time
newTimerWheel = TimerWheel []

insertTimer ::
  (Ord time) => time -> TimerId -> TimerWheel time -> TimerWheel time
insertTimer time timerId (TimerWheel agenda) =
  TimerWheel (sort ((time, timerId) : agenda))

deleteTimer :: TimerId -> TimerWheel time -> TimerWheel time
deleteTimer timerId (TimerWheel agenda) =
  TimerWheel (filter ((/= timerId) . snd) agenda)

nextTimer :: TimerWheel time -> Maybe (time, TimerId)
nextTimer (TimerWheel []) = Nothing
nextTimer (TimerWheel (next : _agenda)) = Just next
