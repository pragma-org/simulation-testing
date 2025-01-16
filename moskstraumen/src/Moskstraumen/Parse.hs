module Moskstraumen.Parse (module Moskstraumen.Parse) where

import Control.Monad.Reader
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Read as Text

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

hasIntField :: Field -> Parser Int
hasIntField field = do
  message <- ask
  lift (isInt =<< Map.lookup field message.body.fields)

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

runParser :: Parser a -> Message -> Maybe a
runParser parser message = runReaderT parser message
