{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedLists #-}

module Moskstraumen.Message3 (module Moskstraumen.Message3) where

import Data.Aeson
import Data.Aeson.KeyMap (delete)
import qualified Data.Aeson.KeyMap as KeyMap
import Data.Aeson.Types
import Data.ByteString (ByteString)
import Data.ByteString.Lazy (LazyByteString)
import qualified Data.ByteString.Lazy as LBS
import Data.Char (toLower)
import Debug.Trace
import GHC.Generics (Rep)

import Moskstraumen.NodeId
import Moskstraumen.Prelude

------------------------------------------------------------------------
--
newtype MessageId = MessageId Word64
  deriving newtype (Eq, Ord, Show, Num)
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

data Message i = Message
  { src :: NodeId
  , dest :: NodeId
  , msgId :: Maybe MessageId
  , body :: i
  }
  deriving stock (Show, Eq)

data Response o = Response
  { src :: NodeId
  , dest :: NodeId
  , msgId :: Maybe MessageId
  , inReplyTo :: MessageId
  , body :: o
  }
  deriving stock (Show, Eq)

data RpcError = Timeout
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON)

data Incoming i o
  = InMessage (Message i)
  | InResponse (Response o)
  | InRpcError RpcError
  deriving stock (Show, Eq)

data Outgoing i o
  = OutMessage (Message i)
  | OutResponse (Response o)
  deriving stock (Show, Eq)

------------------------------------------------------------------------
--
data MaelstromMessage a = MaelstromMessage
  { src :: NodeId
  , dest :: NodeId
  , body :: MaelstromBody a
  }
  deriving stock (Show)

data MaelstromBody a = MaelstromBody
  { msg_id :: Maybe MessageId
  , in_reply_to :: Maybe MessageId
  , payload :: a
  }
  deriving stock (Show)

aesonOptions :: Options
aesonOptions =
  defaultOptions
    { sumEncoding =
        TaggedObject
          { tagFieldName = "type"
          , contentsFieldName = "contents"
          }
    , tagSingleConstructors = True
    , -- NOTE: This is imporant, otherwisw "init_ok" won't parse into Init_ok.
      allNullaryToStringTag = False
    , constructorTagModifier = map toLower
    , omitNothingFields = True
    }

parseMaelstrom :: Value -> Parser (MaelstromMessage Value)
parseMaelstrom = withObject "MaelstromMessage" $ \v ->
  MaelstromMessage
    <$> v
    .: "src"
    <*> v
    .: "dest"
    <*> case KeyMap.lookup "body" v of
      Just body -> parseMaelstromBody body
      Nothing -> fail "parseMaelstrom: no body"

parseMaelstromBody :: Value -> Parser (MaelstromBody Value)
parseMaelstromBody = withObject "MaelstromBody" $ \v ->
  MaelstromBody
    <$> v
    .:? "msg_id"
    <*> v
    .:? "in_reply_to"
    <*> pure (Object (delete "in_reply_to" (delete "msg_id" v)))

decodeMaelstrom ::
  LazyByteString -> Either String (MaelstromMessage Value)
decodeMaelstrom lbs =
  parseEither parseMaelstrom =<< eitherDecode lbs

gparser ::
  (Generic a, GFromJSON Zero (Rep a)) => Value -> Either String a
gparser = parseEither (genericParseJSON aesonOptions)

fromMaelstrom ::
  (Generic i, GFromJSON Zero (Rep i), Generic o, GFromJSON Zero (Rep o)) =>
  MaelstromMessage Value
  -> Either String (Incoming i o)
fromMaelstrom mmsg = case mmsg.body.in_reply_to of
  Nothing -> case gparser mmsg.body.payload of
    Right i ->
      Right
        $ InMessage
          Message
            { src = mmsg.src
            , dest = mmsg.dest
            , msgId = mmsg.body.msg_id
            , body = i
            }
    Left err -> Left err
  Just inReplyTo -> case gparser mmsg.body.payload of
    Right o ->
      Right
        $ InResponse
          Response
            { src = mmsg.src
            , dest = mmsg.dest
            , msgId = mmsg.body.msg_id
            , inReplyTo = inReplyTo
            , body = o
            }
    Left err -> Left err

decodeIncoming ::
  ( Generic i
  , GFromJSON Zero (Rep i)
  , Generic o
  , GFromJSON Zero (Rep o)
  ) =>
  ByteString
  -> Either String (Incoming i o)
decodeIncoming bs = fromMaelstrom =<< decodeMaelstrom (LBS.fromStrict bs)

decodeOutgoing = undefined

toMaelstromMessage :: Message i -> MaelstromMessage i
toMaelstromMessage msg =
  MaelstromMessage
    { src = msg.src
    , dest = msg.dest
    , body =
        MaelstromBody
          { msg_id = msg.msgId
          , in_reply_to = Nothing
          , payload = msg.body
          }
    }
toMaelstromResponse :: Response o -> MaelstromMessage o
toMaelstromResponse reply =
  MaelstromMessage
    { src = reply.src
    , dest = reply.dest
    , body =
        MaelstromBody
          { msg_id = reply.msgId
          , in_reply_to = Just reply.inReplyTo
          , payload = reply.body
          }
    }

toJsonMaelstromBody ::
  (Generic a, GToJSON' Value Zero (Rep a)) => MaelstromBody a -> Value
toJsonMaelstromBody mbody =
  object
    ( ["msg_id" .= mbody.msg_id, "in_reply_to" .= mbody.in_reply_to]
        <> case genericToJSON aesonOptions mbody.payload of
          Object kvs -> KeyMap.toList kvs
    )

encodeMaelstrom ::
  (Generic a, GToJSON' Value Zero (Rep a)) =>
  MaelstromMessage a
  -> LazyByteString
encodeMaelstrom mmsg =
  encode
    $ object
      [ "src" .= mmsg.src
      , "dest" .= mmsg.dest
      , "body" .= toJsonMaelstromBody mmsg.body
      ]

encodeMessage ::
  (Generic i, GToJSON' Value Zero (Rep i)) =>
  Message i
  -> ByteString
encodeMessage msg = LBS.toStrict (encodeMaelstrom (toMaelstromMessage msg))

encodeResponse ::
  (Generic o, GToJSON' Value Zero (Rep o)) => Response o -> ByteString
encodeResponse reply = LBS.toStrict (encodeMaelstrom (toMaelstromResponse reply))

encodeOutgoing ::
  ( Generic i
  , GToJSON' Value Zero (Rep i)
  , Generic o
  , GToJSON' Value Zero (Rep o)
  ) =>
  Outgoing i o
  -> ByteString
encodeOutgoing (OutMessage message) = encodeMessage message
encodeOutgoing (OutResponse resposne) = encodeResponse resposne
