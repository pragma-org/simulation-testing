{-# LANGUAGE DuplicateRecordFields #-}

module Main where

import System.Environment
import System.Exit

import Moskstraumen.Example.Amaru
import Moskstraumen.Example.Echo
import Moskstraumen.Simulate

------------------------------------------------------------------------

libMainBlackbox :: [String] -> IO ()
libMainBlackbox args =
  case args of
    (binary : workloadArg : numberOfNodesArg : numberOfTestsArg : args') -> do
      workload <- case workloadArg of
        "echo" -> return echoWorkload
        "amaru" -> amaruWorkload
        _otherwise ->
          error ("libMainBlackbox: unknown workload: " <> workloadArg)

      let (disableShrinking', args'') = case args' of
            "--disable-shrinking" : rest -> (True, rest)
            _otherwise -> (False, args')
      ok <-
        blackboxTestWith
          defaultTestConfig
            { numberOfTests = read numberOfTestsArg
            , numberOfNodes = read numberOfNodesArg
            , disableShrinking = disableShrinking'
            }
          binary
          ( \seed -> case workloadArg of
              "echo" -> [show seed]
              "amaru" -> args''
              _otherwise ->
                error ("libMainBlackbox: unknown workload: " <> workloadArg)
          )
          workload
      if ok
        then exitSuccess
        else exitFailure
    _otherwise -> do
      putStrLn
        "Expected arguments: <binary> <workload> <# of tests>"
      exitFailure

main :: IO ()
main = libMainBlackbox =<< getArgs
