module Moskstraumen.Effect (module Moskstraumen.Effect) where

import Moskstraumen.Message
import Moskstraumen.NodeId
import Moskstraumen.Prelude
import Moskstraumen.VarId

------------------------------------------------------------------------

-- Defunctionalise?
-- https://www.pathsensitive.com/2019/07/the-best-refactoring-youve-never-heard.html
data Effect node input output
  = SEND NodeId NodeId input
  | REPLY NodeId NodeId (Maybe MessageId) output
  | LOG Text
  | SET_TIMER Int {- µs -} (Maybe MessageId) (node ())
  | DO_RPC NodeId NodeId input (node ()) (output -> node ())
  | DELIVER_VAR VarId output
  | AWAIT_VAR VarId (Maybe Message) (output -> node ())
