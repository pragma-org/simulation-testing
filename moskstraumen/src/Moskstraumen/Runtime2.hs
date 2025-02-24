module Moskstraumen.Runtime2 (module Moskstraumen.Runtime2) where

import qualified Data.ByteString.Char8 as BS8
import qualified Data.Text.IO as Text
import System.IO
import System.Timeout (timeout)

import Moskstraumen.Codec
import Moskstraumen.Message
import Moskstraumen.Prelude
import Moskstraumen.Time
import qualified Moskstraumen.Time as Time

------------------------------------------------------------------------

type Microseconds = Int

data Runtime m = Runtime
  { receive :: m [(Time, Message)]
  , send :: Message -> m ()
  , log :: Text -> m ()
  , timeout ::
      Microseconds
      -> m [(Time, Message)]
      -> m (Maybe [(Time, Message)])
  , getCurrentTime :: m Time
  , shutdown :: m ()
  }

consoleRuntime :: Codec -> IO (Runtime IO)
consoleRuntime codec = do
  hSetBuffering stdin LineBuffering
  hSetBuffering stdout LineBuffering
  hSetBuffering stderr LineBuffering
  return
    Runtime
      { receive = consoleReceive
      , send = consoleSend
      , log = \text -> Text.hPutStrLn stderr text
      , -- NOTE: `timeout 0` times out immediately while negative values
        -- don't, hence the `max 0`.
        timeout = \micros -> System.Timeout.timeout (max 0 micros)
      , getCurrentTime = Time.getCurrentTime
      , shutdown = return ()
      }
  where
    consoleReceive :: IO [(Time, Message)]
    consoleReceive = do
      -- XXX: Batch and read several lines?
      line <- BS8.hGetLine stdin
      if BS8.null line
        then return []
        else do
          BS8.hPutStrLn stderr ("recieve: " <> line)
          case codec.decode line of
            Right message -> do
              now <- Time.getCurrentTime
              return [(now, message)]
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
