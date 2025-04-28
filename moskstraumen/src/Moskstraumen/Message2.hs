{-# LANGUAGE FlexibleContexts #-}

module Moskstraumen.Message2 (
  MessageId,
  Message (Message, src, dest, body, msgId, inReplyTo),
  parseMessage,
  decodeMessage,
  encodeMessage,
  t,
) where

import Data.Aeson (
  FromJSON,
  ToJSON,
  Value (..),
  parseJSON,
  withObject,
  (.:?),
  (.=),
 )
import qualified Data.Aeson as Json
import qualified Data.Aeson.KeyMap as Json
import Data.Aeson.Types (Parser)
import qualified Data.Aeson.Types as Json
import Data.ByteString.Lazy (ByteString)
import Data.Char (toLower)
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
  deriving stock (Show, Functor)

decodeMaelstromBody ::
  (FromJSON a) => Value -> Parser (MaelstromBody a)
decodeMaelstromBody = withObject "MaelstromBody" $ \v ->
  MaelstromBody
    <$> v
    .:? "msg_id"
    <*> v
    .:? "in_reply_to"
    <*> parseJSON (Object (Json.delete "in_reply_to" (Json.delete "msg_id" v)))

maelstromBodyToJSON ::
  (Generic a, Json.GToJSON' Value Json.Zero (Rep a), ToJSON a) =>
  MaelstromBody a
  -> Value
maelstromBodyToJSON mbody =
  Json.toJSON
    $ Json.fromList
      [ ("msg_id", Json.toJSON mbody.msg_id)
      , ("in_reply_to", Json.toJSON mbody.in_reply_to)
      ]
    <> case Json.genericToJSON
      Json.defaultOptions
        { Json.sumEncoding = Json.defaultTaggedObject {Json.tagFieldName = "type"}
        , Json.tagSingleConstructors = True
        , Json.constructorTagModifier = map toLower
        , Json.omitNothingFields = True
        }
      mbody.payload of
      Json.Object kvs -> kvs
      _otherwise ->
        error
          "maelstromBodyToJSON: impossible, toJSON on payload will always be an object"

parseMessage :: (FromJSON a) => Value -> Either String (Message a)
parseMessage = Json.parseEither $ \value -> do
  msg <- Json.parseJSON value :: Parser (MaelstromMessage Value)
  body <- decodeMaelstromBody msg.body
  return
    Message
      { src = msg.src
      , dest = msg.dest
      , msgId = body.msg_id
      , inReplyTo = body.in_reply_to
      , body = body.payload
      }

decodeMessage :: (FromJSON a) => ByteString -> Either String (Message a)
decodeMessage bs = do
  value <- Json.eitherDecode bs
  parseMessage value

encodeMessage ::
  (Generic a, ToJSON a, Json.GToJSON' Value Json.Zero (Rep a)) =>
  Message a
  -> ByteString
encodeMessage message =
  Json.encode
    MaelstromMessage
      { src = message.src
      , dest = message.dest
      , body =
          maelstromBodyToJSON
            MaelstromBody
              { msg_id = message.msgId
              , in_reply_to = message.inReplyTo
              , payload = message.body
              }
      }

------------------------------------------------------------------------

data Echo = Echo {echo :: Text}
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
