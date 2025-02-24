module Moskstraumen.Runtime.TCP (module Moskstraumen.Runtime.TCP) where

import Control.Concurrent
import Control.Concurrent.STM
import qualified Control.Exception as E
import Control.Monad (forever, unless, void)
import qualified Data.ByteString as S
import qualified Data.List.NonEmpty as NE
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.Text.IO as Text
import Network.Socket
import Network.Socket.ByteString (recv, sendAll)
import System.IO
import System.Timeout

import Moskstraumen.Codec
import Moskstraumen.Message
import Moskstraumen.NodeId
import Moskstraumen.Prelude
import Moskstraumen.Runtime2
import Moskstraumen.Time (Time)
import qualified Moskstraumen.Time as Time

------------------------------------------------------------------------

type Port = Int

noNeighbours :: Map NodeId Port
noNeighbours = Map.empty

-- >>> tcpEventLoop echo () echoValidateMarshal 3000
-- echo -n "{\"body\":{\"type\":\"echo\",\"echo\": \"hi\"}, \"src\": \"c1\", \"dest\":\"n1\"}" | nc 127.0.0.1 3000
tcpRuntime :: Port -> Map NodeId Port -> Codec -> IO (Runtime IO)
tcpRuntime port neighbours codec = do
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
      , getCurrentTime = Time.getCurrentTime
      , shutdown = killThread tid
      }

server ::
  Int -> Codec -> TBQueue [(Time, Message)] -> TBQueue Message -> IO ()
server port codec receiveQueue sendQueue = runTCPServer Nothing (show port) talk
  where
    talk s = do
      bytes <- recv s 1024
      unless (S.null bytes) $ do
        case codec.decode bytes of
          Left err -> hPutStrLn stderr err
          Right request -> do
            -- XXX: assert request.dest == ourNodeId
            now <- Time.getCurrentTime
            atomically (writeTBQueue receiveQueue [(now, request)])
            -- BUG: this isn't right, as some other thread can write to
            -- the sendQueue... Possible solutions:
            --   1. Merge send and receive? (Could simplify `NodeHandle`
            --      also?). I tried this, and couldn't see how it would
            --      work...
            --   2. Some kind of map in shared memory which keys being
            --      sockets? Problem is: how do we know that all `send`s
            --      have been made and it's ok to return? Rework the semantics
            --      so that we get [Message] to send at the end, rather than
            --      having SEND being part of [Effect]?! Or equivalently: do
            --      only one runtime.send in event loop.
            --   3. One channel pair per peer?
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
