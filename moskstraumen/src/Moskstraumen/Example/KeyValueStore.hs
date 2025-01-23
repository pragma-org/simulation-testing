module Moskstraumen.Example.KeyValueStore (module Moskstraumen.Example.KeyValueStore) where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe

import Moskstraumen.Message
import Moskstraumen.Node3
import Moskstraumen.NodeId
import Moskstraumen.Parse
import Moskstraumen.Prelude

------------------------------------------------------------------------

data Input
  = Init {node_id :: NodeId, node_ids :: [NodeId]}
  | Txn {txn :: [MicroOp]}

data MicroOp
  = R Key [Value]
  | Append Key Value

type Key = Value

data Output
  = InitOk
  | TxnOk {txn :: [MicroOp]}

type State = Map Key [Value]

initialState :: State
initialState = Map.empty

keyValueStore :: Input -> Node State Input Output
keyValueStore (Init myNodeId nodeIds) = do
  info ("Initialising: " <> unNodeId myNodeId)
  setPeers nodeIds
  reply InitOk
keyValueStore (Txn ops) = do
  store <- getState
  let (store', ops') = go [] ops store
  putState store'
  reply (TxnOk ops')
  where
    go acc [] store = (store, reverse acc)
    go acc (op : ops') store = case op of
      R key [] ->
        go
          (R key (concat (maybeToList (Map.lookup key store))) : acc)
          ops'
          store
      R _key (_ : _) -> error "keyValueStore: client read contains values"
      Append key value ->
        go
          (Append key value : acc)
          ops'
          (Map.insertWith (\new old -> old <> new) key [value] store)

------------------------------------------------------------------------

validateInput_ :: Parser Input
validateInput_ =
  asum
    [ Init
        <$ hasKind "init"
        <*> hasNodeIdField "node_id"
        <*> hasListField "node_ids" isNodeId
    , Txn
        <$ hasKind "txn"
        <*> hasListField "txn" validateMicroOp
    ]

validateMicroOp :: Value -> Maybe MicroOp
validateMicroOp (List [String "r", k, List []]) = Just (R k [])
validateMicroOp (List [String "append", k, v]) = Just (Append k v)
validateMicroOp _ = Nothing

marshalInput_ :: Input -> (MessageKind, [(Field, Value)])
marshalInput_ (Init _myNodeId _myNeighbours) = ("init", [])
marshalInput_ (Txn _ops) = ("txn", [])

marshalOutput_ :: Output -> (MessageKind, [(Field, Value)])
marshalOutput_ InitOk = ("init_ok", [])
marshalOutput_ (TxnOk ops) = ("txn_ok", [("txn", List (map marshalMicroOp ops))])

marshalMicroOp :: MicroOp -> Value
marshalMicroOp (R key values) = List [String "r", key, List values]
marshalMicroOp (Append key value) = List [String "append", key, value]

validateOutput_ :: Parser Output
validateOutput_ =
  asum
    [ InitOk <$ hasKind "init_ok"
    , TxnOk <$ hasKind "txn_ok" <*> pure [] -- XXX: not used...
    ]

------------------------------------------------------------------------

libMain :: IO ()
libMain =
  consoleEventLoop
    keyValueStore
    initialState
    ValidateMarshal
      { validateInput = validateInput_
      , validateOutput = validateOutput_
      , marshalInput = marshalInput_
      , marshalOutput = marshalOutput_
      }
