module Moskstraumen.Interface (module Moskstraumen.Interface) where

import qualified Data.ByteString.Char8 as BS8
import Data.IORef
import qualified Data.Text.IO as Text
import System.IO
import System.Process

import Moskstraumen.Codec
import Moskstraumen.Message
import Moskstraumen.Node
import Moskstraumen.Parse
import Moskstraumen.Prelude

------------------------------------------------------------------------

data Interface m = Interface
  { handle :: Message -> m [Message]
  , close :: m ()
  }

------------------------------------------------------------------------

pureSpawn ::
  Parser input
  -> (input -> Node state ())
  -> state
  -> IO (Interface IO)
pureSpawn parse node initialState = do
  ref <- newIORef (initialNodeState initialState)
  return
    Interface
      { handle = \message -> case runParser parse message of
          Nothing -> return []
          Just input -> do
            nodeState <- readIORef ref
            let nodeState' = snd (runNode (node input) (nodeState {incoming = Just message}))
            outgoing <- flip foldMapM (reverse nodeState'.effects)
              $ \effect -> do
                case effect of
                  Send message' -> return [message']
                  Log text -> do
                    Text.hPutStr stderr text
                    Text.hPutStr stderr "\n"
                    hFlush stderr
                    return []
            writeIORef ref (nodeState' {effects = []})
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
