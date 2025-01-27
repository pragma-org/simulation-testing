module Moskstraumen.Runtime2 (module Moskstraumen.Runtime2) where

import qualified Data.ByteString.Char8 as BS8
import Data.IORef
import qualified Data.Text.IO as Text
import Data.Time
import System.IO
import System.Timeout (timeout)

import Moskstraumen.Codec
import Moskstraumen.Message
import Moskstraumen.NodeId
import Moskstraumen.Prelude
import Moskstraumen.TimerWheel2

------------------------------------------------------------------------

type Microseconds = Int

data Runtime m = Runtime
  { receive :: m [Message]
  , send :: Message -> m ()
  , log :: Text -> m ()
  , timeout :: Microseconds -> m [Message] -> m (Maybe [Message])
  , setTimer :: Microseconds -> Maybe MessageId -> (() -> m ()) -> m ()
  , popTimer :: m (Maybe (UTCTime, (Maybe MessageId, () -> m ())))
  , removeTimerByMessageId :: MessageId -> m ()
  , getCurrentTime :: m UTCTime
  }

consoleRuntime :: Codec -> IO (Runtime IO)
consoleRuntime codec = do
  timerWheelRef <- newIORef newTimerWheel
  return
    Runtime
      { receive = consoleReceive
      , send = consoleSend
      , log = \text -> Text.hPutStrLn stderr text >> hFlush stderr
      , -- NOTE: `timeout 0` times out immediately while negative values
        -- don't, hence the `max 0`.
        timeout = \micros -> System.Timeout.timeout (max 0 micros)
      , getCurrentTime = Data.Time.getCurrentTime
      , setTimer = setTimer_ timerWheelRef
      , popTimer = undefined
      , removeTimerByMessageId = undefined
      }
  where
    consoleReceive :: IO [Message]
    consoleReceive = do
      -- XXX: Batch and read several lines?
      line <- BS8.hGetLine stdin
      case codec.decode line of
        Right message -> return [message]
        Left err ->
          -- XXX: Log and keep stats instead of error.
          error
            $ "consoleReceive: failed to decode message: "
            ++ show err

    consoleSend :: Message -> IO ()
    consoleSend message = do
      BS8.hPutStr stdout (codec.encode message)
      BS8.hPutStr stdout "\n"
      hFlush stdout

    setTimer_ ::
      IORef (TimerWheel UTCTime (Maybe MessageId, (() -> IO ())))
      -> Int
      -> Maybe MessageId
      -> (() -> IO ())
      -> IO ()
    setTimer_ timerWheelRef micros mMessageId effects = do
      now <- Data.Time.getCurrentTime
      let later = addUTCTime (realToFrac (fromIntegral micros / 1_000_000)) now
      modifyIORef'
        timerWheelRef
        (insertTimer later (mMessageId, effects))
