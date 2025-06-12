module Moskstraumen.Debugger.State (module Moskstraumen.Debugger.State) where

import Data.Aeson
import Data.Int
import Data.Time.Clock (UTCTime, secondsToNominalDiffTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Data.Vector (Vector)
import qualified Data.Vector as Vector

import Moskstraumen.Debugger.SequenceDiagram (Arrow (..), generate)
import Moskstraumen.Prelude

------------------------------------------------------------------------

data InstanceStateRepr = InstanceStateRepr
  { state :: String
  , currentEvent :: DebEvent
  , -- , runningVersion :: Int64
    receivedTime :: Int64 -- nanoseconds since posix-epoch
  , logs :: [String]
  , sent :: [DebEvent]
  }
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

data DebEvent = DebEvent
  { from :: String
  , to :: String
  , event :: String
  , receivedLogical :: Int
  , -- , receivedSimulated :: Time
    message :: String
  }
  deriving stock (Generic, Show)
  deriving anyclass (FromJSON, ToJSON)

data InstanceState = InstanceState
  { isState :: String -- Should probably be per reactor
  , isCurrentEvent :: DebEvent
  , -- , isRunningVersion :: Int64
    isReceivedTime :: UTCTime
  , isSeqDia :: Int -> String -- the current height
  , isLogs :: [String]
  , isSent :: [DebEvent]
  }

toArrowDE :: DebEvent -> Arrow String
toArrowDE de =
  Arrow
    { aFrom = from de
    , aTo = to de
    , aAt = receivedLogical de
    , aMessage = event de
    }

toArrowIS :: InstanceStateRepr -> [Arrow String]
toArrowIS is = toArrowDE (currentEvent is) : map toArrowDE' (sent is)
  where
    -- we don't want to select the sent messages
    toArrowDE' d = toArrowDE d {receivedLogical = -1}

fromRepr :: Vector InstanceStateRepr -> Vector InstanceState
fromRepr xs = Vector.imap repr xs
  where
    arrows = concatMap toArrowIS $ Vector.toList xs
    repr :: Int -> InstanceStateRepr -> InstanceState
    repr currentIx i =
      InstanceState
        { isState = state i
        , isCurrentEvent = currentEvent i
        , -- , isRunningVersion = runningVersion i
          isReceivedTime =
            posixSecondsToUTCTime
              $ (/ (1_000_000_000))
              $ secondsToNominalDiffTime
              $ fromInteger (fromIntegral (receivedTime i))
        , isSeqDia = generate arrows currentIx
        , isLogs = logs i
        , isSent = sent i
        }
