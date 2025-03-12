module Moskstraumen.Message (module Moskstraumen.Message) where

import Data.Aeson (
  FromJSON,
  ToJSON,
  ToJSONKey,
  pairs,
  withObject,
  (.:),
  (.:?),
  (.=),
 )
import qualified Data.Aeson as Json
import qualified Data.Aeson.Key as Json
import qualified Data.Aeson.KeyMap as Json
import Data.Coerce
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Scientific (floatingOrInteger)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time (UTCTime)
import qualified Data.Vector as Vector
import Data.Word

import Moskstraumen.NodeId
import Moskstraumen.Prelude
import Moskstraumen.Time

------------------------------------------------------------------------

-- start snippet Message
data Message = Message
  { src :: NodeId
  , dest :: NodeId
  , body :: Payload
  }
  -- end snippet
  deriving stock (Eq, Ord, Show)

newtype MessageKind = MessageKind Text
  deriving stock (Generic)
  deriving newtype (Eq, Ord, Show, Semigroup, Monoid, IsString)
  deriving anyclass (FromJSON, ToJSON)

type MessageId = Word64

data Payload = Payload
  { kind :: MessageKind
  , msgId :: Maybe MessageId
  , inReplyTo :: Maybe MessageId
  , fields :: Map Field Value
  }
  deriving stock (Eq, Ord, Show)

newtype Field = Field Text
  deriving stock (Generic, Show)
  deriving newtype (Eq, Ord, IsString)
  deriving anyclass (ToJSON, FromJSON, ToJSONKey)

data Value
  = String Text
  | Int Int
  | Double Double
  | List [Value]
  | Map (Map Text Value)
  | Bool Bool
  deriving stock (Eq, Ord, Show)

instance IsString Value where
  fromString = String . Text.pack

------------------------------------------------------------------------

instance ToJSON Message where
  toJSON message =
    Json.object
      [ "src" .= message.src
      , "dest" .= message.dest
      , "body" .= Json.toJSON message.body
      ]

instance FromJSON Message where
  parseJSON = withObject "Message" $ \v ->
    Message
      <$> v
      .: "src"
      <*> v
      .: "dest"
      <*> v
      .: "body"

instance ToJSON Payload where
  toJSON payload =
    Json.object
      $ [ "type" .= payload.kind
        ]
      <> maybe [] ((: []) . ("msg_id" .=)) payload.msgId
      <> maybe [] ((: []) . ("in_reply_to" .=)) payload.inReplyTo
      <> foldMap
        (\(Field field, value) -> [Json.fromText field .= value])
        (Map.toList payload.fields)

instance FromJSON Payload where
  parseJSON = withObject "Payload" $ \v ->
    Payload
      <$> v
      .: "type"
      <*> v
      .:? "msg_id"
      <*> v
      .:? "in_reply_to"
      <*> pure (fields' v)
    where
      fields' =
        Map.map parseJsonValue
          . Map.mapKeys
            coerce
          . Map.delete "type"
          . Map.delete "msg_id"
          . Map.delete "in_reply_to"
          . Json.toMapText

      parseJsonValue (Json.Object obj) = Map (Map.map parseJsonValue (Json.toMapText obj))
      parseJsonValue (Json.Array xs) = List (map parseJsonValue (Vector.toList xs))
      parseJsonValue (Json.String text) = String text
      parseJsonValue (Json.Number s) = case floatingOrInteger s of
        Left double -> Double double
        Right int -> Int int
      parseJsonValue (Json.Bool bool) = Bool bool
      parseJsonValue Json.Null = List []

instance ToJSON Value where
  toJSON (String text) = Json.String text
  toJSON (Int int) = Json.Number (fromInteger (fromIntegral int))
  toJSON (Map keyValues) = Json.Object (Json.fromMapText (Map.map Json.toJSON keyValues))
  toJSON (List values) = Json.Array (Vector.fromList (map Json.toJSON values))
  toJSON (Bool bool) = Json.Bool bool

instance FromJSON Value where
  parseJSON = Json.withText "String" (pure . String)

------------------------------------------------------------------------

makeInitMessage :: NodeId -> [NodeId] -> Message
makeInitMessage myNodeId myNeighbours =
  Message
    { src = "c0"
    , dest = myNodeId
    , body =
        Payload
          { kind = "init"
          , msgId = Just 0
          , inReplyTo = Nothing
          , fields =
              Map.fromList
                [
                  ( "node_id"
                  , String (unNodeId myNodeId)
                  )
                , ("node_ids", List (map (String . unNodeId) myNeighbours))
                ]
          }
    }

------------------------------------------------------------------------

unit_encodeMessage =
  Json.encode
    ( Message
        { src = "n1"
        , dest = "n2"
        , body =
            Payload
              { kind = "echo"
              , msgId = Just 0
              , inReplyTo = Nothing
              , fields = Map.fromList [("echo", "foo")]
              }
        }
    )

unit_decodeMessage =
  Json.decode
    "{\"src\": \"c1\", \"dest\": \"n1\", \"body\": {\"msg_id\": 1, \"type\": \"echo\", \"echo\": \"hello there\"}}"
    == Just
      ( Message
          { src = "c1"
          , dest = "n1"
          , body =
              Payload
                { kind = "echo"
                , msgId = Just 1
                , inReplyTo = Nothing
                , fields = Map.fromList [("echo", "hello there")]
                }
          }
      )
