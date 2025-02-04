module Moskstraumen.Example.CRDT.GSet (module Moskstraumen.Example.CRDT.GSet) where

import Control.Monad.State
import Data.Set (Set)
import qualified Data.Set as Set

import Moskstraumen.Codec
import Moskstraumen.EventLoop2
import Moskstraumen.Message
import Moskstraumen.Node4
import Moskstraumen.NodeId
import Moskstraumen.Parse
import Moskstraumen.Prelude

------------------------------------------------------------------------

data GSetInput
  = Init {node_id :: NodeId, node_ids :: [NodeId]}
  | Add {element :: Value}
  | Read
  | Replicate {value :: Set Value}

data GSetOutput
  = InitOk
  | AddOk
  | ReadOk {value :: Set Value}

type GSetState = Set Value

initialState :: GSetState
initialState = Set.empty

gset ::
  GSetInput -> Node GSetState GSetInput GSetOutput
gset (Init myNodeId myNeighbours) = do
  info ("Initialising: " <> unNodeId myNodeId)
  setNodeId myNodeId
  setPeers myNeighbours
  every 5_000_000 $ do
    values <- getState
    forM_ myNeighbours $ \neighbour ->
      unless (neighbour == myNodeId)
        $ send neighbour (Replicate values)
  reply InitOk
gset (Add value) = do
  modifyState (Set.insert value)
  reply AddOk
gset Read = do
  values <- getState
  reply (ReadOk values)
gset (Replicate values) =
  modifyState (values `Set.union`)

------------------------------------------------------------------------

gsetValidateInput :: Parser GSetInput
gsetValidateInput =
  asum
    [ Init
        <$ hasKind "init"
        <*> hasNodeIdField "node_id"
        <*> hasListField "node_ids" isNodeId
    , Add
        <$ hasKind "add"
        <*> hasValueField "element"
    , Read <$ hasKind "read"
    , Replicate
        <$ hasKind "replicate"
        <*> (Set.fromList <$> hasListField "value" Just)
    ]

gsetMarshalInput ::
  GSetInput -> (MessageKind, [(Field, Value)])
gsetMarshalInput (Init myNodeId myNeighbours) = ("init", [])
gsetMarshalInput (Add value) = ("add", [("element", value)])
gsetMarshalInput Read = ("read", [])
gsetMarshalInput (Replicate values) = ("replicate", [("value", List (Set.toList values))])

gsetMarshalOutput ::
  GSetOutput -> (MessageKind, [(Field, Value)])
gsetMarshalOutput InitOk = ("init_ok", [])
gsetMarshalOutput AddOk = ("add_ok", [])
gsetMarshalOutput (ReadOk values) = ("read_ok", [("value", List (Set.toList values))])

gsetValidateOutput :: Parser GSetOutput
gsetValidateOutput =
  asum
    [ InitOk <$ hasKind "init_ok"
    , AddOk <$ hasKind "topology_ok"
    , ReadOk
        <$ hasKind "read_ok"
        <*> (Set.fromList <$> hasListField "value" Just)
    ]

------------------------------------------------------------------------

libMain :: IO ()
libMain =
  consoleEventLoop
    gset
    initialState
    ValidateMarshal
      { validateInput = gsetValidateInput
      , validateOutput = gsetValidateOutput
      , marshalInput = gsetMarshalInput
      , marshalOutput = gsetMarshalOutput
      }
