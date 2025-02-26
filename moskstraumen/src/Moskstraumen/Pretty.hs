module Moskstraumen.Pretty (module Moskstraumen.Pretty) where

import Moskstraumen.Error
import Moskstraumen.Message
import Moskstraumen.Prelude

------------------------------------------------------------------------

type Pretty output = output -> (MessageKind, [(Field, Value)])

marshal :: Pretty output -> output -> Message
marshal pretty = undefined

marshalRPCError :: Pretty RPCError
marshalRPCError (Timeout text) = errorMessage 0 text
marshalRPCError (NotSupported text) = errorMessage 10 text
marshalRPCError (TemporarilyUnavailable text) = errorMessage 11 text
marshalRPCError (MalformedRequest text) = errorMessage 12 text
marshalRPCError (Crash text) = errorMessage 13 text
marshalRPCError (Abort text) = errorMessage 14 text
marshalRPCError (KeyDoesNotExist text) = errorMessage 20 text
marshalRPCError (KeyAlreadyExists text) = errorMessage 21 text
marshalRPCError (PreconditionFailed text) = errorMessage 22 text
marshalRPCError (TxnConflict text) = errorMessage 30 text
marshalRPCError (CustomError code text) = errorMessage code text

errorMessage :: Int -> Text -> (MessageKind, [(Field, Value)])
errorMessage code text = ("error", [("code", Int code), ("text", String text)])
