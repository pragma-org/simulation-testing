module Moskstraumen.Pretty (module Moskstraumen.Pretty) where

import Moskstraumen.Message
import Moskstraumen.Prelude

------------------------------------------------------------------------

type Pretty output = output -> (MessageKind, [(Field, Value)])

marshal :: Pretty output -> output -> Message
marshal pretty = undefined
