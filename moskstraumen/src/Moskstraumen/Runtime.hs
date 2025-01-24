module Moskstraumen.Runtime (module Moskstraumen.Runtime) where

import qualified Data.ByteString.Char8 as BS8
import Data.IORef
import qualified Data.Text.IO as Text
import Data.Time
import System.IO
import System.Timeout (timeout)

import Moskstraumen.Codec
import Moskstraumen.Message
import Moskstraumen.Prelude
import Moskstraumen.TimerWheel

------------------------------------------------------------------------

data Runtime m = Runtime
  { source :: m Event
  , sink :: Effect -> m ()
  }

data Event = MessageEvent Message | TimerEvent TimerId | ExitEvent
  deriving (Eq)

data Effect
  = SEND Message
  | LOG Text
  | TIMER TimerId Int

------------------------------------------------------------------------

consoleRuntime :: Codec -> IO (Runtime IO)
consoleRuntime codec = do
  timerWheelRef <- newIORef newTimerWheel
  return
    Runtime
      { source = consoleSource timerWheelRef
      , sink = consoleSink timerWheelRef
      }
  where
    consoleSource :: IORef (TimerWheel UTCTime) -> IO Event
    consoleSource timerWheelRef = do
      timerWheel <- readIORef timerWheelRef

      let decodeMessage line = case codec.decode line of
            Right message -> return (MessageEvent message)
            Left err ->
              error
                $ "consoleSource: failed to decode message: "
                ++ show err

      case nextTimer timerWheel of
        Nothing -> do
          line <- BS8.hGetLine stdin
          decodeMessage line
        Just (time, timerId) -> do
          now <- getCurrentTime
          let nanos = realToFrac (diffUTCTime time now)
              micros = round (nanos * 1_000_000)
          -- NOTE: `timeout 0` times out immediately while negative values
          -- don't, hence the `max 0`.
          mLine <- timeout (max 0 micros) (BS8.hGetLine stdin)
          case mLine of
            Nothing -> do
              writeIORef timerWheelRef (deleteTimer timerId timerWheel)
              return (TimerEvent timerId)
            Just line -> decodeMessage line

    consoleSink :: IORef (TimerWheel UTCTime) -> Effect -> IO ()
    consoleSink _timerWheelRef (SEND message) = do
      BS8.hPutStr stdout (codec.encode message)
      BS8.hPutStr stdout "\n"
      hFlush stdout
    consoleSink _timerWheelRef (LOG text) = do
      Text.hPutStr stderr text
      Text.hPutStr stderr "\n"
      hFlush stderr
    consoleSink timerWheelRef (TIMER timerId micros) = do
      now <- getCurrentTime
      let later = addUTCTime (realToFrac (fromIntegral micros / 1_000_000)) now
      modifyIORef' timerWheelRef (insertTimer later timerId)
