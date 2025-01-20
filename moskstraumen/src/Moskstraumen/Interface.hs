module Moskstraumen.Interface (module Moskstraumen.Interface) where

import qualified Data.ByteString.Char8 as BS8
import Data.IORef
import qualified Data.Text.IO as Text
import System.IO
import System.Process

import Moskstraumen.Codec
import Moskstraumen.Message
import Moskstraumen.Node2
import Moskstraumen.Parse
import Moskstraumen.Prelude

------------------------------------------------------------------------

data Interface m = Interface
  { handle :: Message -> m [Message]
  , close :: m ()
  }

------------------------------------------------------------------------

pureSpawn ::
  (input -> Node state input output)
  -> state
  -> ValidateMarshal input output
  -> IO (Interface IO)
pureSpawn node initialState validateMarshal = do
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

------------------------------------------------------------------------

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
