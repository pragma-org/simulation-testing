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
        "ExampleTests"
        [ testCase
            "Broadcast"
            (assertBool "" =<< unit_simTestBroadcastReplay (-320952954625588303))
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
