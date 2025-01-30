module Moskstraumen.Interface2 (module Moskstraumen.Interface2) where

import Control.Concurrent
import Control.Concurrent.MVar
import Control.Concurrent.STM
import qualified Data.ByteString.Char8 as BS8
import qualified Data.Text.IO as Text
import Data.Time
import System.IO
import System.Process
import System.Timeout

import Moskstraumen.Codec
import Moskstraumen.EventLoop2
import Moskstraumen.Message
import Moskstraumen.Node4
import Moskstraumen.Prelude
import Moskstraumen.Runtime2
import Moskstraumen.Time

------------------------------------------------------------------------

data Interface m = Interface
  { handle :: Message -> m [Message]
  , close :: m ()
  }

simulationRuntime :: IO (Interface IO, Runtime IO)
simulationRuntime = do
  inputMVar <- newEmptyMVar
  outputQueue <- newTBQueueIO 65536
  fakeTime <- newFakeTime
  let
    handle_ :: Message -> IO [Message]
    handle_ input = do
      putMVar inputMVar input
      atomically $ do
        len <- lengthTBQueue outputQueue
        guard (len /= 0)
        replicateM (fromIntegral len) (readTBQueue outputQueue)

    recieve_ :: IO [Message]
    recieve_ = do
      input <- takeMVar inputMVar
      return [input]

    send_ :: Message -> IO ()
    send_ = atomically . writeTBQueue outputQueue

  return
    ( Interface
        { handle = handle_
        , close = return ()
        }
    , Runtime
        { receive = recieve_
        , send = send_
        , log = Text.hPutStrLn stderr
        , timeout = \micros receive -> do
            now <- getFakeTime fakeTime
            messages <- receive
            case messages of
              [] -> error "simulationRuntime: impossible"
              [message] -> do
                case message.arrivalTime of
                  Nothing -> error "simulationRuntime: messages must have arrival times"
                  Just arrivalTime_ ->
                    if arrivalTime_ < addTimeMicros micros now
                      then do
                        setFakeTime fakeTime arrivalTime_
                        return (Just [message])
                      else return Nothing
              _ -> error "simulationRuntime: impossible"
        , getCurrentTime = getFakeTime fakeTime
        }
    )

simulationSpawn ::
  (input -> Node state input output)
  -> state
  -> ValidateMarshal input output
  -> IO (Interface IO)
simulationSpawn node initialState validateMarshal = do
  (interface, runtime) <- simulationRuntime
  tid <- forkIO (eventLoop node initialState validateMarshal runtime)
  return interface {close = killThread tid}

{-
pureSpawn ::
  (input -> Node state input output)
  -> state
  -> ValidateMarshal input output
  -> IO (Interface IO)
pureSpawn node initialState validateMarshal = do
  undefined

nodeStateRef <- newIORef (initialNodeState initialState)
return
  Interface
    { handle = \message -> case runParser validateMarshal.validateInput message of
        Nothing -> return []
        Just input -> do
          nodeState <- readIORef nodeStateRef
          let nodeContext =
                NodeContext
                  { request = message
                  , validateMarshal = validateMarshal
                  }
          let (nodeState', effects) = runNode (node input) nodeContext nodeState
          outgoing <- flip foldMapM effects $ \effect -> do
            case effect of
              SEND message' -> return [message']
              LOG text -> do
                Text.hPutStr stderr text
                Text.hPutStr stderr "\n"
                hFlush stderr
                return []
          writeIORef nodeStateRef nodeState'
          return outgoing
    , close = return ()
    }
 -}

pipeInterface :: Handle -> Handle -> ProcessHandle -> Interface IO
pipeInterface hin hout processHandle =
  Interface
    { handle = \msg -> do
        BS8.hPutStr hin (encode jsonCodec msg)
        BS8.hPutStr hin "\n"
        hFlush hin
        line <- BS8.hGetLine hout
        case decode jsonCodec line of
          Left err -> hPutStrLn stderr err >> return []
          Right msg' -> return [msg']
    , close = terminateProcess processHandle
    }

pipeSpawn :: FilePath -> IO (Interface IO)
pipeSpawn fp = do
  (Just hin, Just hout, _, processHandle) <-
    createProcess
      (proc fp []) {std_in = CreatePipe, std_out = CreatePipe}
  return (pipeInterface hin hout processHandle)
