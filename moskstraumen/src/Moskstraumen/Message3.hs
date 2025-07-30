{-# LANGUAGE DataKinds #-}
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
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Debug.Trace
import GHC.Generics (Rep)
import GHC.Records

import Moskstraumen.Fault
import Moskstraumen.NodeId
import Moskstraumen.Prelude

------------------------------------------------------------------------
--
newtype MessageId = MessageId Word64
  deriving newtype (Eq, Ord, Show, Num, Enum)
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

data Message i = Message
  { src :: NodeId
  , dest :: NodeId
  , msgId :: Maybe MessageId
  , body :: i
  }
  deriving stock (Show, Eq, Ord)

data Response o = Response
  { src :: NodeId
  , dest :: NodeId
  , msgId :: Maybe MessageId
  , inReplyTo :: MessageId
  , body :: o
  }
  deriving stock (Show, Eq, Ord)

data RpcError = Timeout
  deriving stock (Show, Eq, Ord, Generic)
  deriving anyclass (FromJSON)

data Incoming i o
  = InMessage (Message i)
  | InResponse (Response o)
  | InRpcError RpcError
  | InFault Fault
  | InTimer NodeId
  deriving stock (Show, Eq, Ord)

instance HasField "src" (Incoming i o) NodeId where
  getField (InMessage msg) = msg.src
  getField (InResponse resp) = resp.src
  getField (InRpcError _err) = error "Incoming.src InRpcError"
  getField (InTimer nodeId) = error "Incoming.src InTimer"

instance HasField "dest" (Incoming i o) NodeId where
  getField (InMessage msg) = msg.dest
  getField (InResponse resp) = resp.dest
  getField (InRpcError _err) = error "Incoming.dest InRpcError"

instance HasField "body" (Incoming i o) (Either i o) where
  getField (InMessage msg) = Left msg.body
  getField (InResponse resp) = Right resp.body
  getField (InRpcError _err) = error "Incoming.body InRpcError"

instance HasField "src" (Outgoing i o) NodeId where
  getField (OutMessage msg) = msg.src
  getField (OutResponse resp) = resp.src
  getField (OutRpcError _err) = error "Outgoing.src OutRpcError"

instance HasField "dest" (Outgoing i o) NodeId where
  getField (OutMessage msg) = msg.dest
  getField (OutResponse resp) = resp.dest
  getField (OutRpcError _err) = error "Outgoing.dest OutRpcError"

instance HasField "body" (Outgoing i o) (Either i o) where
  getField (OutMessage msg) = Left msg.body
  getField (OutResponse resp) = Right resp.body
  getField (OutRpcError _err) = error "Outgoing.body InRpcError"

data Outgoing i o
  = OutMessage (Message i)
  | OutResponse (Response o)
  | OutRpcError RpcError
  | OutFault Fault
  | Dropped (Incoming i o)
  deriving stock (Show, Eq)

incomingToOutgoing :: Incoming i o -> Outgoing i o
incomingToOutgoing (InMessage msg) = OutMessage msg
incomingToOutgoing (InResponse resp) = OutResponse resp
incomingToOutgoing (InRpcError err) = OutRpcError err
incomingToOutgoing (InFault fault) = OutFault fault
incomingToOutgoing (InTimer {}) = error "incomingToOutgoing: timer"

outgoingToIncoming :: Outgoing i o -> Incoming i o
outgoingToIncoming (OutMessage msg) = InMessage msg
outgoingToIncoming (OutResponse resp) = InResponse resp
outgoingToIncoming (OutRpcError err) = InRpcError err
outgoingToIncoming (OutFault _fault) = error "outgoingToIncoming: fault"

isClientResponse :: Outgoing i o -> Bool
isClientResponse OutMessage {} = False
isClientResponse (OutResponse (Response {dest})) = isClientNodeId dest
isClientResponse OutRpcError {} = False

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
          _ -> error "toJsonMaelstromBody: impossible, payload is always an object"
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

------------------------------------------------------------------------

addMessageIds ::
  forall time i o. [(time, Incoming i o)] -> [(time, Incoming i o)]
addMessageIds =
  zipWith
    ( \i (time, incoming) -> case incoming of
        InMessage message ->
          ( time
          , InMessage
              ( message {msgId = Just (MessageId (fromIntegral i))} ::
                  Message i
              )
          )
        _otherwise ->
          error
            "addMessageIds, impossible, only called on newly generated messages"
    )
    [0 ..]

pairReplies ::
  forall i o. [Outgoing i o] -> [(Message i, Maybe (Response o))]
pairReplies outgoing =
  [ (message, message.msgId >>= \msgId -> Map.lookup msgId responses)
  | message <- messages
  ]
  where
    (messages, responses) = splitOutgoing outgoing

    splitOutgoing ::
      [Outgoing i o] -> ([Message i], Map MessageId (Response o))
    splitOutgoing = go [] Map.empty
      where
        go ::
          [Message i]
          -> Map MessageId (Response o)
          -> [Outgoing i o]
          -> ([Message i], Map MessageId (Response o))
        go ms rs [] = (reverse ms, rs)
        go ms rs (OutMessage m : os) = go (m : ms) rs os
        go ms rs (OutResponse r : os) =
          go ms (Map.insert r.inReplyTo r rs) os
        go _ms _rs (OutRpcError _e : _os) = error "pariReplies: RpcError"
        go ms rs (OutFault _e : os) = go ms rs os
        go ms rs (Dropped _i : os) = go ms rs os
