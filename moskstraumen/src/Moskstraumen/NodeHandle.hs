module Moskstraumen.NodeHandle (module Moskstraumen.NodeHandle) where

import Control.Concurrent
import Control.Concurrent.STM
import qualified Data.ByteString.Char8 as BS8
import qualified Data.Text.IO as Text
import System.IO
import System.Process

import Moskstraumen.Codec
import Moskstraumen.EventLoop2
import Moskstraumen.FakeTime
import Moskstraumen.Message
import Moskstraumen.Node4
import Moskstraumen.Prelude
import Moskstraumen.Random
import Moskstraumen.Runtime2
import Moskstraumen.Time

------------------------------------------------------------------------

-- start snippet NodeHandle
data NodeHandle = NodeHandle
  { handle :: Time -> Message -> IO [Message]
  , close :: IO ()
  }

-- end snippet

simulationRuntime :: IO (NodeHandle, Runtime IO)
simulationRuntime = do
  inputMVar <- newEmptyMVar
  outputQueue <- newTBQueueIO 65536
  fakeTime <- newFakeTime
  let
    handle_ :: Time -> Message -> IO [Message]
    handle_ arrivalTime input = do
      putMVar inputMVar (arrivalTime, input)
      atomically $ do
        len <- lengthTBQueue outputQueue
        guard (len /= 0)
        replicateM (fromIntegral len) (readTBQueue outputQueue)

    recieve_ :: IO [(Time, Message)]
    recieve_ = do
      (arrivalTime, input) <- takeMVar inputMVar
      return [(arrivalTime, input)]

    send_ :: Message -> IO ()
    send_ = atomically . writeTBQueue outputQueue

  return
    ( NodeHandle
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
              [(arrivalTime, message)] -> do
                if arrivalTime < addTimeMicros micros now
                  then do
                    setFakeTime fakeTime arrivalTime
                    return (Just [(arrivalTime, message)])
                  else return Nothing
              _ -> error "simulationRuntime: impossible"
        , getCurrentTime = getFakeTime fakeTime
        , shutdown = return ()
        }
    )

simulationSpawn ::
  (input -> Node state input output)
  -> state
  -> Prng
  -> ValidateMarshal input output
  -> IO NodeHandle
simulationSpawn node initialState initialPrng validateMarshal = do
  (interface, runtime) <- simulationRuntime
  tid <-
    forkIO (eventLoop node initialState initialPrng validateMarshal runtime)
  return interface {close = killThread tid}

{-
pureSpawn ::
  (input -> Node state input output)
  -> state
  -> ValidateMarshal input output
  -> IO (NodeHandle IO)
pureSpawn node initialState validateMarshal = do
  undefined

nodeStateRef <- newIORef (initialNodeState initialState)
return
  NodeHandle
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

pipeNodeHandle :: Handle -> Handle -> ProcessHandle -> NodeHandle
pipeNodeHandle hin hout processHandle =
  NodeHandle
    { handle = \_arrivalTime msg -> do
        BS8.hPutStr hin (encode jsonCodec msg)
        BS8.hPutStr hin "\n"
        hFlush hin
        line <- BS8.hGetLine hout
        case decode jsonCodec line of
          Left err -> hPutStrLn stderr err >> return []
          Right msg' -> return [msg']
    , close = terminateProcess processHandle
    }

pipeSpawn :: FilePath -> [String] -> IO NodeHandle
pipeSpawn fp args = do
  (Just hin, Just hout, _, processHandle) <-
    createProcess
      (proc fp args) {std_in = CreatePipe, std_out = CreatePipe}
  return (pipeNodeHandle hin hout processHandle)
