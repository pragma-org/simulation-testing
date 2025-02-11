module Moskstraumen.Example.Raft (module Moskstraumen.Example.Raft) where

import Control.Monad.State.Strict
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe
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

eLECTION_TIMEOUT_MICROS :: Int
eLECTION_TIMEOUT_MICROS = 2_000_000 -- 2s.

------------------------------------------------------------------------

data Input
  = Init {node_id :: NodeId, node_ids :: [NodeId]}
  | Read {key :: Key}
  | Write {key :: Key, value :: RaftValue}
  | Cas {key :: Key, from :: RaftValue, to :: RaftValue}
  | RequestVote
      { term_ :: Term
      , candidate_id :: NodeId
      , last_log_index :: Int
      , last_log_term :: Term
      }

data Output
  = InitOk
  | ReadOk {value :: RaftValue}
  | KeyDoesntExist Text
  | WriteOk
  | PreconditionFailed Text
  | CasOk
  | RequestVoteRes {term_ :: Term, vote_granted :: Bool}

type Key = Int
type RaftValue = Int

data Role = Follower | Candidate | Leader
  deriving (Eq)

type Store = Map Key RaftValue

type Term = Word64

data RaftState = RaftState
  { store :: Store
  , role :: Role
  , electionDeadline :: Time
  , stepDownDeadline :: Time
  , term :: Term
  , votedFor :: Maybe NodeId
  , votes :: Set NodeId
  , log :: Log
  }

initialState :: RaftState
initialState =
  RaftState
    { store = Map.empty
    , role = Follower
    , term = 0
    , votedFor = Nothing
    , votes = Set.empty
    , electionDeadline = epoch
    , stepDownDeadline = epoch
    , log = initialLog
    }

------------------------------------------------------------------------

newtype Log = Log [Entry]

data Entry = Entry {entryTerm :: Term, op :: Input}

initialLog :: Log
initialLog = Log [dummyEntry]
  where
    dummyEntry = Entry 0 (Read 0)

(!) :: Log -> Int -> Entry
Log entries ! index = entries !! (index - 1)

appendLog :: Log -> [Entry] -> Log
appendLog (Log entries) entries' = Log (entries ++ entries')

lastEntry :: Log -> Entry
lastEntry (Log entries) = last entries

size :: Log -> Int
size (Log entries) = length entries

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
  info ("Leader election, setting deadline: " <> fromString (show now))
  modifyState (\raftState -> raftState {electionDeadline = now})
  raftState <- getState
  every 1_000 $ do
    jitter <- random
    sleep (round (jitter * 1000)) $ do
      now' <- getTime
      info
        ( "Leader election, deadline: "
            <> fromString (show raftState.electionDeadline)
            <> ", now: "
            <> fromString (show now')
        )
      when (raftState.electionDeadline < now') $ do
        if raftState.role /= Leader
          then becomeCandidate
          else resetElectionDeadline
  every 1_000 $ do
    raftState <- getState
    now <- getTime
    when (raftState.role == Leader && raftState.electionDeadline < now) $ do
      info "Stepping down: haven't received any acks recently"
      becomeFollower
  reply InitOk
raft (RequestVote remoteTerm candidateId lastLogIndex lastLogTerm) = do
  maybeStepDown remoteTerm
  myTerm <- term <$> getState
  votedFor <- votedFor <$> getState
  log <- log <$> getState
  voteGranted <-
    if remoteTerm < myTerm
      then do
        info
          ( "Candidate term "
              <> textShow remoteTerm
              <> " lower than "
              <> textShow myTerm
              <> ", not granting vote."
          )
        return False
      else
        if isJust votedFor
          then do
            info
              ("Already voted for " <> textShow votedFor <> "; not granting vote.")
            return False
          else
            if lastLogTerm < entryTerm (lastEntry log)
              then do
                info
                  $ "Have log entries from term "
                  <> textShow (entryTerm (lastEntry log))
                  <> ", which is newer than remote term "
                  <> textShow lastLogTerm
                  <> "; not granting vote."
                return False
              else
                if lastLogTerm == entryTerm (lastEntry log) && lastLogIndex < size log
                  then do
                    info
                      $ "Our logs are both at term "
                      <> textShow (entryTerm (lastEntry log))
                      <> ", but our log is "
                      <> textShow (size log)
                      <> " and theirs is only "
                      <> textShow lastLogIndex
                      <> "long; not granting vote."
                    return False
                  else do
                    info ("Granting vote to " <> textShow candidateId)
                    modifyState (\raftState -> raftState {votedFor = Just candidateId})
                    resetElectionDeadline
                    return True

  reply (RequestVoteRes myTerm voteGranted)
raft input = do
  raftState <- getState
  let (store', output) = apply input raftState.store
  putState raftState {store = store'}
  reply output

becomeCandidate :: Node RaftState Input Output
becomeCandidate = do
  modifyState (\raftState -> raftState {role = Candidate})
  term <- term <$> get
  advanceTerm (term + 1)
  resetElectionDeadline
  resetStepDownDeadline
  info ("Become canidate for term " <> fromString (show term))
  requestVotes

becomeFollower :: Node RaftState input output
becomeFollower = do
  term <- term <$> get
  info ("Become follower for term " <> fromString (show term))
  modifyState (\raftState -> raftState {role = Follower})
  resetElectionDeadline

resetElectionDeadline :: Node RaftState input output
resetElectionDeadline = do
  raftState <- getState
  now <- getTime
  jitter <- random
  putState
    raftState
      { electionDeadline =
          addTimeMicros
            (round (fromIntegral eLECTION_TIMEOUT_MICROS * (jitter + 1)))
            now
      }

advanceTerm :: Term -> Node RaftState input output
advanceTerm term' = do
  raftState <- getState
  -- Term can't go backwards.
  assertM (raftState.term < term')
  put raftState {term = term'}

maybeStepDown :: Term -> Node RaftState input output
maybeStepDown remoteTerm = do
  term <- term <$> getState
  when (term < remoteTerm) $ do
    info
      ( "Stepping down: remote term "
          <> textShow remoteTerm
          <> " higher than our term "
          <> textShow term
      )
    advanceTerm remoteTerm
    becomeFollower

requestVotes :: Node RaftState Input Output
requestVotes = do
  myNodeId <- getNodeId
  modifyState (\raftState -> raftState {votes = Set.singleton myNodeId})
  myTerm <- term <$> getState
  log <- log <$> getState
  brpc
    (RequestVote myTerm myNodeId (size log) (entryTerm (lastEntry log)))
    (info "brcp failed")
    $ \output -> case output of
      RequestVoteRes remoteTerm voteGranted -> do
        maybeStepDown remoteTerm
        role <- role <$> getState
        myTerm' <- term <$> getState
        when
          ( role
              == Candidate
              && myTerm
              == myTerm'
              && myTerm
              == remoteTerm
              && voteGranted
          )
          $ do
            resetStepDownDeadline
            remoteNodeId <- getSender
            raftState <- getState
            let votes' = Set.insert remoteNodeId raftState.votes
            put raftState {votes = votes'}
            info ("Have votes: " <> textShow votes')

            myNeighbours <- getPeers
            when (majority (length myNeighbours) <= Set.size votes')
              $
              -- We have a majority of votes for this term!
              becomeLeader

-- What number would constitute a majority of n nodes?
majority :: Int -> Int
majority n = floor (realToFrac n / 2.0) + 1

becomeLeader :: Node RaftState Input Output
becomeLeader = do
  role <- role <$> getState
  -- Should be a candidate.
  assertM (role == Candidate)
  modifyState (\raftState -> raftState {role = Leader})
  resetStepDownDeadline
  term <- term <$> getState
  info ("Become leader for term " <> textShow term)

resetStepDownDeadline :: Node RaftState Input Output
resetStepDownDeadline = do
  now <- getTime
  modifyState
    ( \nodeState ->
        nodeState {stepDownDeadline = addTimeMicros eLECTION_TIMEOUT_MICROS now}
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
    , RequestVote
        <$ hasKind "request_vote"
        <*> (fromIntegral <$> hasIntField "term")
        <*> hasNodeIdField "candidate_id"
        <*> hasIntField "last_log_index"
        <*> (fromIntegral <$> hasIntField "last_log_term")
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
marshalInput_ (RequestVote term_ candidate_id last_log_index last_log_term) =
  ( "request_vote"
  ,
    [ ("term", Int (fromIntegral term_))
    , ("candidate_id", String (unNodeId candidate_id))
    , ("last_log_index", Int last_log_index)
    , ("last_log_term", Int (fromIntegral last_log_term))
    ]
  )

marshalOutput_ :: Output -> (MessageKind, [(Field, Value)])
marshalOutput_ InitOk = ("init_ok", [])
marshalOutput_ (ReadOk value) = ("read_ok", [("value", Int value)])
marshalOutput_ WriteOk = ("write_ok", [])
marshalOutput_ CasOk = ("cas_ok", [])
marshalOutput_ (KeyDoesntExist msg) = ("error", [("code", Int 20), ("text", String msg)])
marshalOutput_ (PreconditionFailed msg) = ("error", [("code", Int 22), ("text", String msg)])
marshalOutput_ (RequestVoteRes term_ vote_granted) =
  ( "request_vote_res"
  ,
    [ ("term", Int (fromIntegral term_))
    , ("vote_granted", Bool vote_granted)
    ]
  )

-- marshalOutput_ (Error code text) = ("error", [("code", Int code), ("text", String text)])

validateOutput_ :: Parser Output
validateOutput_ =
  asum
    [ InitOk <$ hasKind "init_ok"
    , ReadOk <$ hasKind "read_ok" <*> hasIntField "value"
    , CasOk <$ hasKind "cas_ok"
    , RequestVoteRes
        <$ hasKind "request_vote_res"
        <*> (fromIntegral <$> hasIntField "term")
        <*> hasBoolField "vote_granted"
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
