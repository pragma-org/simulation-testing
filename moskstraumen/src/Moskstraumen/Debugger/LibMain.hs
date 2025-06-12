{-# LANGUAGE OverloadedStrings #-}

module Moskstraumen.Debugger.LibMain (module Moskstraumen.Debugger.LibMain) where

import Brick.BChan
import Control.Concurrent
import Control.Exception (finally)
import Data.Aeson (eitherDecodeFileStrict)
import Data.Time.LocalTime (getCurrentTimeZone)
import System.Environment (getArgs)
import System.Exit (die)

import Moskstraumen.Debugger.State
import Moskstraumen.Debugger.UserInterface (
  AppEvent (UpdateState),
  mkAppState,
  runApp,
 )
import Moskstraumen.Prelude

------------------------------------------------------------------------

libMain :: IO ()
libMain = do
  as <- getArgs
  case as of
    ["watch", fp] -> do
      content <- eitherDecodeFileStrict fp
      case content of
        Left err -> die ("Can't parse debug-file: " <> err)
        Right values -> do
          bchan <- newBChan 1024
          tid <- forkIO (watch fp bchan)
          tz <- getCurrentTimeZone
          runApp (mkAppState tz (fromRepr values)) (Just bchan)
            `finally` killThread tid
    [f] -> do
      content <- eitherDecodeFileStrict f
      case content of
        Left err -> die ("Can't parse debug-file: " <> err)
        Right values -> do
          tz <- getCurrentTimeZone
          runApp (mkAppState tz (fromRepr values)) Nothing
    _ -> die "Debugger wants exactly one input, which is the debug-file"

watch :: FilePath -> BChan AppEvent -> IO ()
watch fp bchan = go
  where
    go :: IO ()
    go = do
      threadDelay 500000
      content <- eitherDecodeFileStrict fp
      case content of
        Left err -> die ("Can't parse debug-file: " <> err)
        Right values -> do
          writeBChan bchan (UpdateState (fromRepr values))
          go
