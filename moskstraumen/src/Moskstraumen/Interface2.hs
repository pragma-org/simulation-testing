module Moskstraumen.Interface2 (module Moskstraumen.Interface2) where

import Control.Concurrent.MVar

import Moskstraumen.Message
import Moskstraumen.Prelude
import Moskstraumen.Runtime2

------------------------------------------------------------------------

data Interface m = Interface
  { handle :: Message -> m [Message]
  , close :: m ()
  }

simulationRuntime :: IO (Interface IO, Runtime IO)
simulationRuntime = do
  inputMVar <- newEmptyMVar
  outputMVar <- newEmptyMVar
  let
    handle_ :: Message -> IO [Message]
    handle_ input = do
      putMVar inputMVar input
      output <- takeMVar outputMVar
      return [output]

    recieve_ :: IO [Message]
    recieve_ = do
      input <- takeMVar inputMVar
      return [input]

    send_ :: Message -> IO ()
    send_ output = putMVar outputMVar output

  return
    ( Interface
        { handle = handle_
        , close = return ()
        }
    , Runtime
        { receive = recieve_
        , send = send_
        , log = undefined
        , timeout = undefined
        , setTimer = undefined
        , peekTimer = undefined
        , removeTimerByMessageId = undefined
        , getCurrentTime = undefined
        }
    )
