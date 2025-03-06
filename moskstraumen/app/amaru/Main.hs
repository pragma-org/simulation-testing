module Main where

import System.Environment

import Moskstraumen.Example.Amaru

------------------------------------------------------------------------

main :: IO ()
main = libMain =<< getArgs
