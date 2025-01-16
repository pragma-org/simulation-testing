module Moskstraumen.Codec (module Moskstraumen.Codec) where

import qualified Data.Aeson as Json
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as BS8

import Moskstraumen.Message
import Moskstraumen.Prelude

------------------------------------------------------------------------

data Codec = Codec
  { decode :: ByteString -> Either String Message
  , encode :: Message -> ByteString
  }

jsonCodec :: Codec
jsonCodec =
  Codec
    { decode = Json.eitherDecode . BS8.fromStrict
    , encode = BS8.toStrict . Json.encode
    }
