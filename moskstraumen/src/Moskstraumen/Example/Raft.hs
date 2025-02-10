module Moskstraumen.Example.Raft (module Moskstraumen.Example.Raft) where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set

import Moskstraumen.Codec
import Moskstraumen.EventLoop2
import Moskstraumen.Message
import Moskstraumen.Node4
import Moskstraumen.NodeId
import Moskstraumen.Parse
import Moskstraumen.Prelude
import Moskstraumen.Time

------------------------------------------------------------------------

eLECTION_TIMEOUT :: Int
eLECTION_TIMEOUT = 2_000_000 -- 2s.

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

data Role = Follower | Candidate | Leader

type Store = Map Key RaftValue

data RaftState = RaftState
  { store :: Store
  , role :: Role
  , electionDeadline :: Time
  , term :: Word64
  , votedFor :: Set NodeId
  }

initialState :: RaftState
initialState =
  RaftState
    { store = Map.empty
    , role = Follower
    , term = 0
    , votedFor = Set.empty
    , electionDeadline = epoch
    }

------------------------------------------------------------------------

apply :: Input -> Store -> (Store, Output)
apply (Read key) store =
  case Map.lookup key store of
    Nothing -> (store, KeyDoesntExist "not found")
    Just value -> (store, ReadOk value)
apply (Write key value) store =
  (Map.insert key value store, WriteOk)
apply (Cas key from to) store =
  case Map.lookup key store of
    Nothing -> (store, KeyDoesntExist "not found")
    Just value
      | value == from ->
          (Map.insert key to store, CasOk)
      | otherwise ->
          ( store
          , PreconditionFailed
              ( "expected "
                  <> fromString (show from)
                  <> ", but had "
                  <> fromString (show value)
              )
          )
apply Init {} _store = error "impossible, already handled"

raft :: Input -> Node RaftState Input Output
raft (Init myNodeId myNeighbours) = do
  info ("Initialising: " <> unNodeId myNodeId)
  setNodeId myNodeId
  setPeers myNeighbours
  now <- getTime
  modifyState (\raftState -> raftState {electionDeadline = now})
  every 1_000_000 $ do
    info "Become candidate"
    modifyState (\raftState -> raftState {role = Candidate})
  reply InitOk
raft input = do
  raftState <- getState
  let (store', output) = apply input raftState.store
  putState raftState {store = store'}
  reply output

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
