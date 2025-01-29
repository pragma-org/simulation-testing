module Moskstraumen.Codec (module Moskstraumen.Codec) where

import qualified Data.Aeson as Json
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as BS8

import Moskstraumen.Message
import Moskstraumen.Parse
import Moskstraumen.Prelude
import Moskstraumen.Pretty

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

data ValidateMarshal input output = ValidateMarshal
  { validateInput :: Parser input
  , validateOutput :: Parser output
  , marshalInput :: Pretty input
  , marshalOutput :: Pretty output
  }
