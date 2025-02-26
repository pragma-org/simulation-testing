module Moskstraumen.Error (module Moskstraumen.Error) where

import Data.Aeson
import Data.Scientific

import Moskstraumen.Prelude

------------------------------------------------------------------------

data RPCError
  = Timeout Text
  | NotSupported Text
  | TemporarilyUnavailable Text
  | MalformedRequest Text
  | Crash Text
  | Abort Text
  | KeyDoesNotExist Text
  | KeyAlreadyExists Text
  | PreconditionFailed Text
  | TxnConflict Text
  | CustomError Int Text
  deriving (Eq, Ord, Show)

{-
instance ToJSON RPCError where
  toJSON (Timeout text) = errorObject 0 text
  toJSON (NotSupported text) = errorObject 10 text
  toJSON (TemporarilyUnavailable text) = errorObject 11 text
  toJSON (MalformedRequest text) = errorObject 12 text
  toJSON (Crash text) = errorObject 13 text
  toJSON (Abort text) = errorObject 14 text
  toJSON (KeyDoesNotExist text) = errorObject 20 text
  toJSON (KeyAlreadyExists text) = errorObject 21 text
  toJSON (PreconditionFailed text) = errorObject 22 text
  toJSON (TxnConflict text) = errorObject 30 text
  toJSON (CustomError code text) = errorObject code text

errorObject :: Int -> Text -> Value
errorObject code text =
  object
    ["type" .= ("error" :: Text), "code" .= code, "text" .= text]

instance FromJSON RPCError where
  parseJSON = withObject "RPCError" $ \obj -> do
    v <- obj .: "code"
    case v of
      Number 0 -> Timeout <$> obj .: "text"
      Number 10 -> NotSupported <$> obj .: "text"
      Number 11 -> TemporarilyUnavailable <$> obj .: "text"
      Number 12 -> MalformedRequest <$> obj .: "text"
      Number 13 -> Crash <$> obj .: "text"
      Number 14 -> Abort <$> obj .: "text"
      Number 20 -> KeyDoesNotExist <$> obj .: "text"
      Number 21 -> KeyAlreadyExists <$> obj .: "text"
      Number 22 -> PreconditionFailed <$> obj .: "text"
      Number 30 -> TxnConflict <$> obj .: "text"
      Number s -> case floatingOrInteger s of
        Left _ -> failWithMessage v
        Right i -> CustomError (fromIntegral i) <$> obj .: "text"
      _otherwise -> failWithMessage v
    where
      failWithMessage v =
        fail ("FromJSON RPCError, code isn't an integer: " ++ show v)
-}
