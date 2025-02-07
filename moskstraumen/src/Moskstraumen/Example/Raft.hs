module Moskstraumen.Example.Raft (module Moskstraumen.Example.Raft) where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map

import Moskstraumen.Codec
import Moskstraumen.EventLoop2
import Moskstraumen.Message
import Moskstraumen.Node4
import Moskstraumen.NodeId
import Moskstraumen.Parse
import Moskstraumen.Prelude
import Moskstraumen.Pretty

------------------------------------------------------------------------

data Input
  = Init {node_id :: NodeId, node_ids :: [NodeId]}
  | Read {key :: Key}
  | Write {key :: Key, value :: RaftValue}
  | Cas {key :: Key, from :: RaftValue, to :: RaftValue}

data Output
  = InitOk
  | ReadOk {value :: RaftValue}
  | KeyDoesntExist Text
  | WriteOk
  | PreconditionFailed Text
  | CasOk

type Key = Int
type RaftValue = Int

type RaftState = Map Key RaftValue

initialState :: RaftState
initialState = Map.empty

------------------------------------------------------------------------

raft :: Input -> Node RaftState Input Output
raft (Init myNodeId myNeighbours) = do
  info ("Initialising: " <> unNodeId myNodeId)
  setNodeId myNodeId
  setPeers myNeighbours
  reply InitOk
raft (Read key) = do
  raftState <- getState
  case Map.lookup key raftState of
    Nothing -> reply (KeyDoesntExist "not found")
    Just value -> reply (ReadOk value)
raft (Write key value) = do
  modifyState (Map.insert key value)
  reply WriteOk
raft (Cas key from to) = do
  raftState <- getState
  case Map.lookup key raftState of
    Nothing -> reply (KeyDoesntExist "not found")
    Just value
      | value == from -> do
          putState (Map.insert key to raftState)
          reply CasOk
      | otherwise ->
          reply
            ( PreconditionFailed
                ( "expected "
                    <> fromString (show from)
                    <> ", but had "
                    <> fromString (show value)
                )
            )

------------------------------------------------------------------------

validateInput_ :: Parser Input
validateInput_ =
  asum
    [ Init
        <$ hasKind "init"
        <*> hasNodeIdField "node_id"
        <*> hasListField "node_ids" isNodeId
    , Read
        <$ hasKind "read"
        <*> hasIntField "key"
    , Write
        <$ hasKind "write"
        <*> hasIntField "key"
        <*> hasIntField "value"
    , Cas
        <$ hasKind "cas"
        <*> hasIntField "key"
        <*> hasIntField "from"
        <*> hasIntField "to"
    ]

marshalInput_ :: Input -> (MessageKind, [(Field, Value)])
marshalInput_ (Init _myNodeId _myNeighbours) = ("init", [])
marshalInput_ (Read key) = ("read", [("key", Int key)])
marshalInput_ (Write key value) = ("write", [("key", Int key), ("value", Int value)])
marshalInput_ (Cas key from to) =
  ( "cas"
  ,
    [ ("key", Int key)
    , ("from", Int from)
    , ("to", Int to)
    ]
  )

marshalOutput_ :: Output -> (MessageKind, [(Field, Value)])
marshalOutput_ InitOk = ("init_ok", [])
marshalOutput_ (ReadOk value) = ("read_ok", [("value", Int value)])
marshalOutput_ WriteOk = ("write_ok", [])
marshalOutput_ CasOk = ("cas_ok", [])
marshalOutput_ (KeyDoesntExist msg) = ("error", [("code", Int 20), ("text", String msg)])
marshalOutput_ (PreconditionFailed msg) = ("error", [("code", Int 22), ("text", String msg)])

-- marshalOutput_ (Error code text) = ("error", [("code", Int code), ("text", String text)])

validateOutput_ :: Parser Output
validateOutput_ =
  asum
    [ InitOk <$ hasKind "init_ok"
    , ReadOk <$ hasKind "read_ok" <*> hasIntField "value"
    , CasOk <$ hasKind "cas_ok"
    --    , Error
    --        <$ hasKind "error"
    --        <*> hasField "code" isInt
    --        <*> hasField "text" isText
    ]

------------------------------------------------------------------------

libMain :: IO ()
libMain =
  consoleEventLoop
    raft
    initialState
    ValidateMarshal
      { validateInput = validateInput_
      , validateOutput = validateOutput_
      , marshalInput = marshalInput_
      , marshalOutput = marshalOutput_
      }
