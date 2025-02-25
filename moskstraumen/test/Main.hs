module Main (main) where

import Test.Tasty
import Test.Tasty.HUnit

import Moskstraumen.Example.Echo

------------------------------------------------------------------------

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests = testGroup "Tests" [unitTests]

unitTests :: TestTree
unitTests =
  testGroup
    "Unit tests"
    [ failingTestCase "blackboxTestEcho" unit_blackboxTestEcho
    , failingTestCase "simulationTestEcho" unit_simulationTestEcho
    ]

------------------------------------------------------------------------

failingTestCase :: String -> IO Bool -> TestTree
failingTestCase name test =
  testCase name (assertBool "failingTestCase" . not =<< test)
