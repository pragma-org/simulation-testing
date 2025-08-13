module Main (main) where

import Test.Tasty
import Test.Tasty.HUnit

import Moskstraumen.Example.Broadcast
import Moskstraumen.Example.Echo
import Moskstraumen.Message
import Moskstraumen.Prelude

import MessageCodec

------------------------------------------------------------------------

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests = testGroup "Tests" [unitTests]

unitTests :: TestTree
unitTests =
  testGroup
    "Tests"
    [ testGroup
        "UnitTests"
        [messageCodecTests]
    , testGroup
        "Simulation"
        [ testCase
            "Broadcast"
            (assertBool "" =<< unit_simTestBroadcast)
        ]
    , testGroup
        "Regression"
        [ testCase
            "Broadcast1"
            (assertBool "" =<< unit_btest)
        , testCase
            "Broadcast2"
            (assertBool "" =<< unit_btest2)
        , testCase
            "Broadcast3"
            (assertBool "" =<< unit_btest3)
        ]
    ]

--     [ failingTestCase "blackboxTestEcho" unit_blackboxTestEcho
--     , failingTestCase "simulationTestEcho" unit_simulationTestEcho
--     , testCase
--         "encodeDecodeMessage"
--         (assertBool "encodeDecode" unit_encodeDecodeMessage)
--     ]

------------------------------------------------------------------------

failingTestCase :: String -> IO Bool -> TestTree
failingTestCase name test =
  testCase name (assertBool "failingTestCase" . not =<< test)
