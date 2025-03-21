module Moskstraumen.Parse (module Moskstraumen.Parse) where

import Control.Monad.Reader
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import qualified Data.Text.Read as Text

import Moskstraumen.Error
import Moskstraumen.Message
import Moskstraumen.NodeId
import Moskstraumen.Prelude

------------------------------------------------------------------------

type Parser a = ReaderT Message Maybe a

satisfies :: (Message -> Bool) -> Parser ()
satisfies predicate = do
  message <- ask
  if predicate message
    then lift (Just ())
    else lift Nothing

hasKind :: MessageKind -> Parser ()
hasKind messageKind =
  satisfies (\message -> message.body.kind == messageKind)

isInt :: Value -> Maybe Int
isInt (Int i) = Just i
isInt _ = Nothing

hasField :: Field -> (Value -> Maybe a) -> Parser a
hasField field fieldParser = do
  message <- ask
  lift (fieldParser =<< Map.lookup field message.body.fields)

hasIntField :: Field -> Parser Int
hasIntField field = hasField field isInt

hasBoolField :: Field -> Parser Bool
hasBoolField field = do
  message <- ask
  text <- lift (Map.lookup field message.body.fields)
  lift (isBool text)

isBool :: Value -> Maybe Bool
isBool (Bool bool) = Just bool
isBool _ = Nothing

isText :: Value -> Maybe Text
isText (String text) = Just text
isText _ = Nothing

hasTextField :: Field -> Parser Text
hasTextField field = do
  message <- ask
  text <- lift (Map.lookup field message.body.fields)
  lift (isText text)

isNodeId :: Value -> Maybe NodeId
isNodeId (String text)
  | "n" `Text.isPrefixOf` text = case Text.decimal (Text.drop 1 text) of
      Left _err -> Nothing
      Right _nodeId -> Just (NodeId text)
  | otherwise = Nothing
isNodeId _ = Nothing

hasNodeIdField :: Field -> Parser NodeId
hasNodeIdField field = do
  message <- ask
  str <- lift (Map.lookup field message.body.fields)
  lift (isNodeId str)

hasListField :: Field -> (Value -> Maybe a) -> Parser [a]
hasListField field itemParser = do
  message <- ask
  value <- lift (Map.lookup field message.body.fields)
  case value of
    List values -> lift (traverse itemParser values)
    _ -> lift Nothing

hasValueField :: Field -> Parser Value
hasValueField field = do
  message <- ask
  lift (Map.lookup field message.body.fields)

hasMapField ::
  Field
  -> (Value -> Maybe value)
  -> Parser (Map Text value)
hasMapField field valueParser = do
  message <- ask
  value <- lift (Map.lookup field message.body.fields)
  case value of
    Map keyValues -> lift (traverse valueParser keyValues)
    _ -> lift Nothing

isList :: (Value -> Maybe a) -> Value -> Maybe [a]
isList itemParser (List values) = traverse itemParser values
isList _itetParser _ = Nothing

isPair ::
  (Value -> Maybe a) -> (Value -> Maybe b) -> Value -> Maybe (a, b)
isPair parseA parseB (List [v1, v2]) = do
  x <- parseA v1
  y <- parseB v2
  return (x, y)
isPair _parseA _parseB _ = Nothing

runParser :: Parser a -> Message -> Maybe a
runParser parser message = runReaderT parser message

rpcErrorParser :: Parser RPCError
rpcErrorParser = do
  code <- hasIntField "code"
  case code of
    0 -> Timeout <$> hasTextField "text"
    10 -> NotSupported <$> hasTextField "text"
    11 -> TemporarilyUnavailable <$> hasTextField "text"
    12 -> MalformedRequest <$> hasTextField "text"
    13 -> Crash <$> hasTextField "text"
    14 -> Abort <$> hasTextField "text"
    20 -> KeyDoesNotExist <$> hasTextField "text"
    21 -> KeyAlreadyExists <$> hasTextField "text"
    22 -> PreconditionFailed <$> hasTextField "text"
    30 -> TxnConflict <$> hasTextField "text"
    i -> CustomError i <$> hasTextField "text"

alt :: Parser a -> Parser b -> Parser (Either a b)
alt parser1 parser2 = do
  message <- ask
  case runParser parser1 message of
    Nothing -> fmap Right parser2
    Just x -> return (Left x)
