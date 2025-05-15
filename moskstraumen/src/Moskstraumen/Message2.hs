{-# LANGUAGE FlexibleContexts #-}

module Moskstraumen.Message2 (
  MessageId,
  Message (Message, src, dest, body, msgId, inReplyTo),
  parseMessage,
  decodeMessage,
  decodeMessage',
  decodeMessageValue,
  decodeMessageValue',
  encodeMessage,
  aesonOptions,
  -- t,
  -- tv,
  t,
) where

import Data.Aeson (
  FromJSON,
  ToJSON,
  Value (..),
  withObject,
  (.:?),
 )
import qualified Data.Aeson as Json
import qualified Data.Aeson.KeyMap as Json
import Data.Aeson.Types (Parser)
import qualified Data.Aeson.Types as Json
import Data.ByteString (ByteString)
import Data.ByteString.Lazy (LazyByteString)
import qualified Data.ByteString.Lazy as LBS
import Data.Char (toLower)
import qualified Data.Text as Text
import Debug.Trace
import GHC.Generics

import Moskstraumen.NodeId
import Moskstraumen.Prelude

------------------------------------------------------------------------

newtype MessageId = MessageId Word64
  deriving newtype (Eq, Ord, Show, Num)
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

------------------------------------------------------------------------

data MaelstromMessage a = MaelstromMessage
  { src :: NodeId
  , dest :: NodeId
  , body :: a
  }
  deriving stock
    (Generic, Show, Functor, Foldable, Traversable)
  deriving anyclass (FromJSON, ToJSON)

data MaelstromBody a = MaelstromBody
  { msg_id :: Maybe MessageId
  , in_reply_to :: Maybe MessageId
  , payload :: a
  }
  deriving stock (Show)

------------------------------------------------------------------------

data Message a = Message
  { src :: NodeId
  , dest :: NodeId
  , msgId :: Maybe MessageId
  , inReplyTo :: Maybe MessageId
  , body :: a
  }
  deriving stock (Eq, Show, Functor, Foldable, Traversable)

aesonOptions :: Json.Options
aesonOptions =
  Json.defaultOptions
    { Json.sumEncoding =
        Json.TaggedObject
          { Json.tagFieldName = "type"
          , Json.contentsFieldName = "contents"
          }
    , Json.tagSingleConstructors = True
    , Json.constructorTagModifier = map toLower
    , Json.omitNothingFields = True
    , Json.unwrapUnaryRecords = True
    }

parseMaelstromBody ::
  (Generic a, FromJSON a, Json.GFromJSON Json.Zero (Rep a)) =>
  Value
  -> Parser (MaelstromBody a)
parseMaelstromBody = withObject "MaelstromBody" $ \v ->
  MaelstromBody
    <$> v
    .:? "msg_id"
    <*> v
    .:? "in_reply_to"
    <*> Json.genericParseJSON
      aesonOptions
      (Object (Json.delete "in_reply_to" (Json.delete "msg_id" v)))

parseMaelstromBodyValue :: Value -> Parser (MaelstromBody Value)
parseMaelstromBodyValue = withObject "MaelstromBody" $ \v ->
  MaelstromBody
    <$> v
    .:? "msg_id"
    <*> v
    .:? "in_reply_to"
    <*> return (Object (Json.delete "in_reply_to" (Json.delete "msg_id" v)))

maelstromBodyToJSON ::
  (Generic a, ToJSON a, Json.GToJSON' Value Json.Zero (Rep a)) =>
  MaelstromBody a
  -> Value
maelstromBodyToJSON mbody =
  Json.toJSON
    $ Json.fromList
      [ ("msg_id", Json.toJSON mbody.msg_id)
      , ("in_reply_to", Json.toJSON mbody.in_reply_to)
      ]
    <> case Json.genericToJSON aesonOptions mbody.payload of
      Json.Object kvs -> kvs
      _otherwise ->
        error
          "maelstromBodyToJSON: impossible, toJSON on payload will always be an object"

parseMessage ::
  (Generic a, FromJSON a, Json.GFromJSON Json.Zero (Rep a)) =>
  Value
  -> Either String (Message a)
parseMessage = Json.parseEither $ \value -> do
  msg <- Json.parseJSON value :: Parser (MaelstromMessage Value)
  body <- parseMaelstromBody msg.body
  return
    Message
      { src = msg.src
      , dest = msg.dest
      , msgId = body.msg_id
      , inReplyTo = body.in_reply_to
      , body = body.payload
      }

parseMessageValue :: Value -> Either String (Message Value)
parseMessageValue = Json.parseEither $ \value -> do
  msg <- Json.parseJSON value :: Parser (MaelstromMessage Value)
  body <- parseMaelstromBodyValue msg.body
  return
    Message
      { src = msg.src
      , dest = msg.dest
      , msgId = body.msg_id
      , inReplyTo = body.in_reply_to
      , body = body.payload
      }

decodeMessage ::
  (Generic a, FromJSON a, Json.GFromJSON Json.Zero (Rep a)) =>
  LazyByteString
  -> Either String (Message a)
decodeMessage bs = do
  value <- Json.eitherDecode bs
  parseMessage value

decodeMessage' ::
  (Generic a, FromJSON a, Json.GFromJSON Json.Zero (Rep a)) =>
  ByteString
  -> Either String (Message a)
decodeMessage' = decodeMessage . LBS.fromStrict

decodeMessageValue :: LazyByteString -> Either String (Message Value)
decodeMessageValue lbs = do
  value <- Json.eitherDecode lbs
  parseMessageValue value

decodeMessageValue' :: ByteString -> Either String (Message Value)
decodeMessageValue' = decodeMessageValue . LBS.fromStrict

encodeMessage ::
  (Generic a, ToJSON a, Json.GToJSON' Value Json.Zero (Rep a)) =>
  Message a
  -> LazyByteString
encodeMessage message =
  Json.encode
    MaelstromMessage
      { src = message.src
      , dest = message.dest
      , body =
          case Json.genericToJSON aesonOptions message.body of
            Json.Object km -> case Json.lookup "contents" km of
              Just (Json.Object contents) -> case Json.lookup "tag" contents of
                Just (Json.String tag) ->
                  Json.toJSON
                    $ Json.fromList
                      [ ("msg_id", Json.toJSON message.msgId)
                      , ("in_reply_to", Json.toJSON message.inReplyTo)
                      , ("type", Json.String (Text.toLower tag))
                      ]
                    <> Json.delete "tag" contents
            _otherwise -> error "encodeMessage"
      }

------------------------------------------------------------------------

{-
data Echo
  = Init {node_id :: NodeId, node_ids :: [NodeId]}
  | Echo {echo :: Text}
  deriving stock (Generic, Show)
  deriving anyclass (FromJSON, ToJSON)

t :: IO ()
t = do
  let bs =
        "{\"id\":94,\"src\":\"c2\",\"dest\":\"n1\",\"body\":{\"echo\":\"Please echo 16\",\"type\":\"echo\",\"msg_id\":47}}"
  case decodeMessage bs :: Either String (Message Echo) of
    Left err -> error err
    Right echo -> do
      print echo
      print $ encodeMessage echo

  let bs' =
        "{\"id\":0,\"src\":\"c0\",\"dest\":\"n1\",\"body\":{\"type\":\"init\",\"node_id\":\"n1\",\"node_ids\":[\"n1\"],\"msg_id\":1}}"
  case decodeMessage bs' :: Either String (Message Echo) of
    Left err -> error err
    Right init0 -> do
      print init0
      print $ encodeMessage init0

tv :: IO ()
tv = do
  let bs =
        "{\"id\":0,\"src\":\"c0\",\"dest\":\"n1\",\"body\":{\"type\":\"init\",\"node_id\":\"n1\",\"node_ids\":[\"n1\"],\"msg_id\":1}}"

  case decodeMessageValue bs :: Either String (Message Value) of
    Left err -> error err
    Right msg -> print msg
 -}

data Broadcast
  = Init {node_id :: NodeId, node_ids :: [NodeId]}
  | Broadcast {message :: Value}
  deriving stock (Generic, Show)
  deriving anyclass (FromJSON, ToJSON)

data BroadCastOk = Init_Ok {test :: Int}
  deriving stock (Generic, Show)
  deriving anyclass (FromJSON, ToJSON)

t :: IO ()
t = do
  print
    $ encodeMessage
      ( Message
          { src = "a"
          , dest = "b"
          , msgId = Just 1
          , inReplyTo = Just 2
          , body = Json.Object (Json.fromList [("tag", Json.String "Init_Ok")])
          }
      )

--  let bs =
--        "{\"id\":4,\"src\":\"c4\",\"dest\":\"n3\",\"body\":{\"type\":\"init\",\"node_id\":\"n3\",\"node_ids\":[\"n1\",\"n2\", \"n3\",\"n4\",\"n5\"],\"msg_id\":1}}"
--
-- case decodeMessageValue' bs :: Either String (Message Value) of
--   Left err -> error err
--   Right bcast -> do
--     print bcast
--     print $ encodeMessage bcast
