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
    [binary, workloadArg, numberOfTests] -> do
      workload <- case workloadArg of
        "echo" -> return echoWorkload
        "amaru" -> amaruWorkload
        _otherwise ->
          error ("libMainBlackbox: unknown workload: " <> workloadArg)
      ok <-
        blackboxTestWith
          defaultTestConfig {numberOfTests = read numberOfTests}
          binary
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
