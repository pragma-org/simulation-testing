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
import qualified Moskstraumen.TimerWheel2 as TimerWheel

------------------------------------------------------------------------

type Microseconds = Int

data Runtime m = Runtime
  { receive :: m [Message]
  , send :: Message -> m ()
  , log :: Text -> m ()
  , timeout :: Microseconds -> m [Message] -> m (Maybe [Message])
  , setTimer :: Microseconds -> Maybe MessageId -> (() -> m ()) -> m ()
  , peekTimer :: m (Maybe (UTCTime, (Maybe MessageId, () -> m ())))
  , -- , popTimer :: m ()
    removeTimerByMessageId :: MessageId -> m ()
  , getCurrentTime :: m UTCTime
  }

consoleRuntime :: Codec -> IO (Runtime IO)
consoleRuntime codec = do
  hSetBuffering stdin LineBuffering
  hSetBuffering stdout LineBuffering
  hSetBuffering stderr LineBuffering
  timerWheelRef <- newIORef emptyTimerWheel
  return
    Runtime
      { receive = consoleReceive
      , send = consoleSend
      , log = \text -> Text.hPutStrLn stderr text
      , -- NOTE: `timeout 0` times out immediately while negative values
        -- don't, hence the `max 0`.
        timeout = \micros -> System.Timeout.timeout (max 0 micros)
      , setTimer = setTimer_ timerWheelRef
      , peekTimer = peekTimer_ timerWheelRef
      , --      , popTimer = popTimer_ timerWheelRef
        removeTimerByMessageId = removeTimer_ timerWheelRef
      , getCurrentTime = Data.Time.getCurrentTime
      }
  where
    consoleReceive :: IO [Message]
    consoleReceive = do
      -- XXX: Batch and read several lines?
      line <- BS8.hGetLine stdin
      if BS8.null line
        then return []
        else do
          BS8.hPutStrLn stderr ("recieve: " <> line)
          case codec.decode line of
            Right message -> return [message]
            Left err ->
              -- XXX: Log and keep stats instead of error.
              error
                $ "consoleReceive: failed to decode message: "
                ++ show err
                ++ "\nline: "
                ++ show line

    consoleSend :: Message -> IO ()
    consoleSend message = do
      BS8.hPutStrLn stderr ("send: " <> codec.encode message)
      BS8.hPutStrLn stdout (codec.encode message)

    setTimer_ ::
      IORef (TimerWheel UTCTime (Maybe MessageId, (() -> IO ())))
      -> Int
      -> Maybe MessageId
      -> (() -> IO ())
      -> IO ()
    setTimer_ timerWheelRef micros mMessageId effects = do
      now <- Data.Time.getCurrentTime
      let later = addUTCTime (realToFrac (fromIntegral micros / 1_000_000)) now
      -- hPutStrLn
      --   stderr
      --   ("setTimer, now: " <> show now <> ", later: " <> show later)
      modifyIORef'
        timerWheelRef
        (insertTimer later (mMessageId, effects))

    peekTimer_ timerWheelRef = do
      timerWheel <- readIORef timerWheelRef
      case TimerWheel.popTimer timerWheel of
        Nothing -> return Nothing
        Just (entry, timerWheel'@(TimerWheel agenda)) -> do
          -- hPutStrLn
          --   stderr
          --   ( "peekTimer, time: "
          --       <> show (fst entry)
          --       <> ", agenda times: "
          --       <> show (map fst agenda)
          --   )
          return (Just entry)

    popTimer_ timerWheelRef = do
      timerWheel <- readIORef timerWheelRef
      case TimerWheel.popTimer timerWheel of
        Nothing -> return ()
        Just (_entry, timerWheel'@(TimerWheel agenda)) -> do
          -- hPutStrLn
          --   stderr
          --   ( "popTimer, time: "
          --       <> show (fst _entry)
          --       <> ", agenda times: "
          --       <> show (map fst agenda)
          --   )
          writeIORef timerWheelRef timerWheel'

    removeTimer_ timerWheelRef messageId =
      modifyIORef timerWheelRef (filterTimer ((== Just messageId) . fst))
