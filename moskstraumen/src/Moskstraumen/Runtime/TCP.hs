module Moskstraumen.Runtime.TCP (module Moskstraumen.Runtime.TCP) where

import Control.Concurrent
import Control.Concurrent.STM
import qualified Control.Exception as E
import qualified Data.ByteString as BS
import Data.IORef
import qualified Data.List.NonEmpty as NE
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.Text.IO as Text
import Network.Socket
import Network.Socket.ByteString (recv, sendAll)
import System.IO
import qualified System.Timeout as Timeout

import Moskstraumen.Codec
import Moskstraumen.Message
import Moskstraumen.NodeId
import Moskstraumen.Prelude
import Moskstraumen.Runtime2
import Moskstraumen.Time (Time)
import qualified Moskstraumen.Time as Time

------------------------------------------------------------------------

rEPLY_TIMEOUT_MICROS :: Int
rEPLY_TIMEOUT_MICROS = 5_000_000 -- 5s.

type Port = Int

noNeighbours :: Map NodeId Port
noNeighbours = Map.empty

-- >>> tcpEventLoop echo () echoValidateMarshal 3000
-- echo -n "{\"body\":{\"type\":\"echo\",\"echo\":\"hi\",\"msg_id\":1}, \"src\": \"c1\", \"dest\":\"n1\"}" | nc 127.0.0.1 3000
tcpRuntime :: Port -> Map NodeId Port -> Codec -> IO (Runtime IO)
tcpRuntime port neighbours codec = do
  receiveQueue <- newTBQueueIO 1024
  replyVarsMap <- newIORef Map.empty
  tid <- forkIO (server port codec receiveQueue replyVarsMap)
  return
    Runtime
      { receive = atomically (readTBQueue receiveQueue)
      , send = sendTcp replyVarsMap
      , log = \text -> Text.hPutStrLn stderr text
      , -- NOTE: `timeout 0` times out immediately while negative values
        -- don't, hence the `max 0`.
        timeout = \micros -> Timeout.timeout (max 0 micros)
      , getCurrentTime = Time.getCurrentTime
      , shutdown = killThread tid
      }
  where
    -- XXX: This wouldn't work if we did several replies. We should refactor
    -- event loop to only do one send (of a list of messages).
    sendTcp ::
      IORef (Map (NodeId, MessageId) (MVar Message)) -> Message -> IO ()
    sendTcp replyVarsMap message =
      case message.body.inReplyTo of
        Nothing -> do
          -- This a bare `send` to another node, not a `reply` nor `rpc`, i.e.
          -- we don't have a reply MVar to write to. In this case we should use
          -- an already established connection to the other node (use the
          -- `neighbours` map).
          error "sendTcp: not implemented yet"
        Just messageId -> do
          m <- readIORef replyVarsMap
          case Map.lookup (message.dest, messageId) m of
            Nothing -> hPutStrLn stderr "send: timeout"
            Just replyMVar -> putMVar replyMVar message

server ::
  Int
  -> Codec
  -> TBQueue [(Time, Message)]
  -> IORef (Map (NodeId, MessageId) (MVar Message))
  -> IO ()
server port codec receiveQueue replyVarsMap = runTCPServer Nothing (show port) talk
  where
    talk :: Socket -> IO ()
    talk s = do
      bytes <- recv s 1024
      unless (BS.null bytes) $ do
        case codec.decode bytes of
          Left err -> hPutStrLn stderr err
          Right request -> do
            -- XXX: assert request.dest == ourNodeId
            case request.body.msgId of
              Nothing -> sendAll s "error: missing message id field"
              Just messageId -> do
                now <- Time.getCurrentTime
                replyMVar <- newEmptyMVar
                atomicModifyIORef'
                  replyVarsMap
                  (\m -> (Map.insert (request.src, messageId) replyMVar m, ()))
                atomically (writeTBQueue receiveQueue [(now, request)])
                mResponse <- Timeout.timeout rEPLY_TIMEOUT_MICROS (takeMVar replyMVar)
                case mResponse of
                  Nothing -> do
                    atomicModifyIORef'
                      replyVarsMap
                      (\m -> (Map.delete (request.src, messageId) m, ()))
                    sendAll s "error: timeout"
                  Just response -> sendAll s (codec.encode response)

-- from the "network-run" package.
runTCPServer ::
  Maybe HostName -> ServiceName -> (Socket -> IO a) -> IO a
runTCPServer mhost port handler = withSocketsDo $ do
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
          forkFinally (handler conn) (const $ gracefulClose conn 5000)
