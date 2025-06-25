module Moskstraumen.Debugger.State (module Moskstraumen.Debugger.State) where

import Data.Aeson
import Data.Int
import Data.Vector (Vector)
import qualified Data.Vector as Vector

import Moskstraumen.Debugger.SequenceDiagram (Arrow (..), generate)
import Moskstraumen.Prelude
import Moskstraumen.Time

------------------------------------------------------------------------

data DebugEvent = DebugEvent
  { state :: Text
  , currentEvent :: SendEvent
  , -- , runningVersion :: Int64
    receivedTime :: Int64 -- nanoseconds since posix-epoch
  , logs :: [Text]
  , sent :: [SendEvent]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data SendEvent = SendEvent
  { from :: Text
  , to :: Text
  , event :: Text
  , receivedLogical :: Int
  , -- , receivedSimulated :: Time
    message :: Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data InstanceState = InstanceState
  { isState :: Text -- Should probably be per reactor
  , isCurrentEvent :: SendEvent
  , -- , isRunningVersion :: Int64
    isReceivedTime :: Time
  , isSeqDia :: Int -> Text -- the current height
  , isLogs :: [Text]
  , isSent :: [SendEvent]
  }

toArrowDE :: SendEvent -> Arrow Text
toArrowDE de =
  Arrow
    { aFrom = from de
    , aTo = to de
    , aAt = receivedLogical de
    , aMessage = event de
    }

toArrowIS :: DebugEvent -> [Arrow Text]
toArrowIS is = toArrowDE (currentEvent is) : map toArrowDE' (sent is)
  where
    -- we don't want to select the sent messages
    toArrowDE' d = toArrowDE d {receivedLogical = -1}

fromRepr :: Vector DebugEvent -> Vector InstanceState
fromRepr xs = Vector.imap repr xs
  where
    arrows = concatMap toArrowIS $ Vector.toList xs
    repr :: Int -> DebugEvent -> InstanceState
    repr currentIx i =
      InstanceState
        { isState = state i
        , isCurrentEvent = currentEvent i
        , -- , isRunningVersion = runningVersion i
          isReceivedTime = fromNanosSinceEpoch i.receivedTime
        , isSeqDia = generate arrows currentIx
        , isLogs = logs i
        , isSent = sent i
        }
