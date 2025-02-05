module Moskstraumen.Runtime.TCP (module Moskstraumen.Runtime.TCP) where

import Control.Concurrent
import Control.Concurrent.STM
import qualified Control.Exception as E
import Control.Monad (forever, unless, void)
import qualified Data.ByteString as S
import qualified Data.List.NonEmpty as NE
import qualified Data.Text.IO as Text
import Data.Time
import Network.Socket
import Network.Socket.ByteString (recv, sendAll)
import System.IO
import System.Timeout

import Moskstraumen.Codec
import Moskstraumen.Message
import Moskstraumen.Prelude
import Moskstraumen.Runtime2

------------------------------------------------------------------------

-- >>> tcpEventLoop echo () echoValidateMarshal 3000
-- echo -n "{\"body\":{\"type\":\"echo\",\"echo\": \"hi\"}, \"src\": \"c1\", \"dest\":\"n1\"}" | nc 127.0.0.1 3000
tcpRuntime :: Int -> Codec -> IO (Runtime IO)
tcpRuntime port codec = do
  receiveQueue <- newTBQueueIO 1024
  sendQueue <- newTBQueueIO 1024
  tid <- forkIO (server port codec receiveQueue sendQueue)
  return
    Runtime
      { receive = atomically (readTBQueue receiveQueue)
      , send = atomically . writeTBQueue sendQueue
      , log = \text -> Text.hPutStrLn stderr text
      , -- NOTE: `timeout 0` times out immediately while negative values
        -- don't, hence the `max 0`.
        timeout = \micros -> System.Timeout.timeout (max 0 micros)
      , getCurrentTime = Data.Time.getCurrentTime
      , shutdown = killThread tid
      }

server :: Int -> Codec -> TBQueue [Message] -> TBQueue Message -> IO ()
server port codec receiveQueue sendQueue = runTCPServer Nothing (show port) talk
  where
    talk s = do
      bytes <- recv s 1024
      unless (S.null bytes) $ do
        case codec.decode bytes of
          Left err -> hPutStrLn stderr err
          Right request -> do
            atomically (writeTBQueue receiveQueue [request])
            -- BUG: this isn't right, as some other thread can write to
            -- the sendQueue... Possible solutions:
            --   1. Merge send and receive? (Could simplify `Interface`
            --      also?)
            --   2. Some kind of map in shared memory which keys being
            --      sockets? Problem is: how do we know that all `send`s
            --      have been made and it's ok to return?
            response <- atomically (readTBQueue sendQueue)
            sendAll s (codec.encode response)

-- from the "network-run" package.
runTCPServer ::
  Maybe HostName -> ServiceName -> (Socket -> IO a) -> IO a
runTCPServer mhost port server = withSocketsDo $ do
  addr <- resolve
  E.bracket (open addr) close loop
  where
    resolve = do
      let hints =
            defaultHints
              { addrFlags = [AI_PASSIVE]
              , addrSocketType = Stream
              }
      NE.head <$> getAddrInfo (Just hints) mhost (Just port)
    open addr = E.bracketOnError (openSocket addr) close $ \sock -> do
      setSocketOption sock ReuseAddr 1
      withFdSocket sock setCloseOnExecIfNeeded
      bind sock $ addrAddress addr
      listen sock 1024
      return sock
    loop sock = forever
      $ E.bracketOnError (accept sock) (close . fst)
      $ \(conn, _peer) ->
        void
          $
          -- 'forkFinally' alone is unlikely to fail thus leaking @conn@,
          -- but 'E.bracketOnError' above will be necessary if some
          -- non-atomic setups (e.g. spawning a subprocess to handle
          -- @conn@) before proper cleanup of @conn@ is your case
          forkFinally (server conn) (const $ gracefulClose conn 5000)
