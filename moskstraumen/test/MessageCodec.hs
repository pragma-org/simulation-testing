{-# LANGUAGE OverloadedLists #-}

module MessageCodec (module MessageCodec) where

import Data.Aeson
import Test.Tasty
import Test.Tasty.HUnit

import Moskstraumen.Prelude

import Moskstraumen.Experiment.Node8 (decodeIncoming, jsonCodec)
import Moskstraumen.Message3 hiding (decodeIncoming)

------------------------------------------------------------------------

data Broadcast = Init {node_id :: String, node_ids :: [String]} | Read
  deriving stock (Generic, Show, Eq)
  deriving anyclass (FromJSON, ToJSON)

data BroadcastOk = Init_ok | Read_ok
  deriving stock (Generic, Show, Eq)
  deriving anyclass (FromJSON, ToJSON)

messageCodecTests :: TestTree
messageCodecTests =
  testGroup
    "MessageCodec"
    [ testCase
        "encodeMessage"
        ( encodeMessage
            Message
              { src = "c1"
              , dest = "n1"
              , msgId = Just 1
              , body = Init {node_id = "n1", node_ids = ["n2"]}
              }
            @?= "{\"body\":{\"in_reply_to\":null,\"msg_id\":1,\"node_id\":\"n1\",\"node_ids\":[\"n2\"],\"type\":\"init\"},\"dest\":\"n1\",\"src\":\"c1\"}"
        )
    , testCase
        "encodeResponse"
        ( encodeResponse
            Response
              { src = "n1"
              , dest = "c1"
              , msgId = Just 1
              , inReplyTo = 1
              , body = Init_ok
              }
            @?= "{\"body\":{\"in_reply_to\":1,\"msg_id\":1,\"type\":\"init_ok\"},\"dest\":\"c1\",\"src\":\"n1\"}"
        )
    , testCase
        "decodeMessage"
        ( ( jsonCodec.decodeIncoming
              "{\"id\":2,\"src\":\"c2\",\"dest\":\"n1\",\"body\":{\"type\":\"init\",\"node_id\":\"n1\",\"node_ids\":[\"n1\",\"n2\",\"n3\",\"n4\",\"n5\"],\"msg_id\":1}}" ::
              Either String (Incoming Broadcast BroadcastOk)
          )
            @?= Right
              ( InMessage
                  Message
                    { src = "c2"
                    , dest = "n1"
                    , msgId = Just 1
                    , body = Init {node_id = "n1", node_ids = ["n1", "n2", "n3", "n4", "n5"]}
                    }
              )
        )
    , testCase
        "decodeResponse"
        ( ( jsonCodec.decodeIncoming
              "{\"id\":3,\"src\":\"n1\",\"dest\":\"c2\",\"body\":{\"type\":\"init_ok\",\"msg_id\":1,\"in_reply_to\":1}}" ::
              Either String (Incoming Broadcast BroadcastOk)
          )
            @?= Right
              ( InResponse
                  Response
                    { src = "n1"
                    , dest = "c2"
                    , msgId = Just 1
                    , inReplyTo = 1
                    , body = Init_ok
                    }
              )
        )
    , testCase
        "decodeRpcError"
        ( False
            @?= False -- TODO:
        )
    ]
