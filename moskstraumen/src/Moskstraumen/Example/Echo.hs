module Moskstraumen.Example.Echo (module Moskstraumen.Example.Echo) where

import Control.Applicative

import Moskstraumen.Message
import Moskstraumen.Node
import Moskstraumen.NodeId
import Moskstraumen.Parse
import Moskstraumen.Prelude

------------------------------------------------------------------------

data EchoInput = Init NodeId [NodeId] | Echo Text

data EchoOutput = InitOk | EchoOk Text

type EchoState = ()

echo :: EchoInput -> Node EchoState ()
echo (Init self neighbours) = do
  setNodeId self
  info ("Initalised: " <> unNodeId self)
  reply InitOk
echo (Echo text) = do
  info ("Got: " <> text)
  reply (EchoOk text)

------------------------------------------------------------------------

libMain :: IO ()
libMain = start echoValidate echo ()

------------------------------------------------------------------------

-- XXX: make this generic...

class Marshal a where
  marshal :: a -> (MessageKind, [(Field, Value)])

reply :: (Marshal output) => output -> Node EchoState ()
reply output = uncurry reply_ (marshal output)

echoValidate :: Parser EchoInput
echoValidate =
  asum
    [ Init
        <$ hasKind "init"
        <*> hasNodeIdField "node_id"
        <*> hasListField "node_ids" isNodeId
    , Echo
        <$ hasKind "echo"
        <*> hasTextField "echo"
    ]

instance Marshal EchoOutput where
  marshal InitOk = ("init_ok", [])
  marshal (EchoOk text) = ("echo_ok", [("echo", String text)])
