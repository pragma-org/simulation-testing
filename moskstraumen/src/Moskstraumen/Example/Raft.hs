module Moskstraumen.Example.Raft (module Moskstraumen.Example.Raft) where

import Control.Monad.State.Strict
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe
import Data.Set (Set)
import qualified Data.Set as Set

import Moskstraumen.Codec
import Moskstraumen.Error
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

hEARTBEAT_INTERVAL_MICROS :: Int
hEARTBEAT_INTERVAL_MICROS = 1_000_000 -- 1s.

mIN_REPLICATION_INTERVAL_MICROS :: Int
mIN_REPLICATION_INTERVAL_MICROS = 50_000 -- 50ms.

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
  | AppendEntries
      { term_ :: Term
      , leader_id :: NodeId
      , prev_log_index :: Int
      , prev_log_term :: Term
      , entries :: Log
      , leader_commit :: Int
      }
  deriving (Show)

data Output
  = InitOk
  | ReadOk {value :: RaftValue}
  | WriteOk
  | CasOk
  | RequestVoteRes {term_ :: Term, vote_granted :: Bool}
  | AppendEntriesOk {success :: Bool, term_ :: Term}
  deriving (Show)

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
  -- ^  When to step down automatically.
  , lastReplication :: Time
  , term :: Term
  , votedFor :: Maybe NodeId
  , votes :: Set NodeId
  , log :: Log
  , commitIndex :: Int
  -- ^ The highest committed entry in the log.
  , nextIndex :: Map NodeId Int
  -- ^ The next index to replicate.
  , matchIndex :: Map NodeId Int
  -- ^  The highest log entry known to be replicated on that node.
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
    , lastReplication = epoch
    , log = initialLog
    , commitIndex = 0
    , nextIndex = Map.empty
    , matchIndex = Map.empty
    }

------------------------------------------------------------------------

newtype Log = Log [Entry]
  deriving newtype (Show)

data Entry = Entry {entryTerm :: Term, op :: Input}
  deriving (Show)

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

fromIndex :: Int -> Log -> Log
fromIndex i (Log entries)
  | i <= 0 = error ("Illegal index: " ++ show i)
  | otherwise = Log (drop (i - 1) entries)

------------------------------------------------------------------------

apply :: Input -> Store -> (Store, Either RPCError Output)
apply (Read key) store =
  case Map.lookup key store of
    Nothing -> (store, Left (KeyDoesNotExist "not found"))
    Just value -> (store, Right (ReadOk value))
apply (Write key value) store =
  (Map.insert key value store, Right WriteOk)
apply (Cas key from to) store =
  case Map.lookup key store of
    Nothing -> (store, Left (KeyDoesNotExist "not found"))
    Just value
      | value == from ->
          (Map.insert key to store, Right CasOk)
      | otherwise ->
          ( store
          , Left
              $ PreconditionFailed
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
  info ("[leader election] setting deadline: " <> fromString (show now))
  modifyState
    ( \raftState -> raftState {electionDeadline = now, stepDownDeadline = now}
    )
  -- Every 0.1s.
  every 100_000 $ do
    -- info "[leader election] leader election thread is running..."
    jitter <- random
    -- info
    --   ("[leader election] sleeping: " <> textShow (round (jitter * 10_000)))
    after (round (jitter * 10_000)) $ do
      raftState <- getState
      now' <- getTime
      info
        ( "[leader election] election deadline in: "
            <> textShow (diffTimeMicros raftState.electionDeadline now')
            <> " µs"
        )
      when (raftState.electionDeadline < now') $ do
        if raftState.role /= Leader
          then becomeCandidate
          else resetElectionDeadline
  -- Leader step down thread, runs every 0.1s.
  every 100_000 $ do
    raftState <- getState
    now <- getTime
    when (raftState.role == Leader && raftState.stepDownDeadline < now) $ do
      info
        "[leader election] Stepping down: haven't received any acks recently"
      becomeFollower
  every mIN_REPLICATION_INTERVAL_MICROS $ do
    replicateLog False
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
          ( "[leader election] Candidate term "
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
              ( "[leader election] Already voted for "
                  <> textShow votedFor
                  <> "; not granting vote."
              )
            return False
          else
            if lastLogTerm < entryTerm (lastEntry log)
              then do
                info
                  $ "[leader election] Have log entries from term "
                  <> textShow (entryTerm (lastEntry log))
                  <> ", which is newer than remote term "
                  <> textShow lastLogTerm
                  <> "; not granting vote."
                return False
              else
                if lastLogTerm == entryTerm (lastEntry log) && lastLogIndex < size log
                  then do
                    info
                      $ "[leader election] Our logs are both at term "
                      <> textShow (entryTerm (lastEntry log))
                      <> ", but our log is "
                      <> textShow (size log)
                      <> " and theirs is only "
                      <> textShow lastLogIndex
                      <> "long; not granting vote."
                    return False
                  else do
                    info ("[leader election] Granting vote to " <> textShow candidateId)
                    modifyState (\raftState -> raftState {votedFor = Just candidateId})
                    resetElectionDeadline
                    return True

  reply (RequestVoteRes myTerm voteGranted)
raft input = do
  raftState <- getState
  if raftState.role /= Leader
    then do
      info "[replication] Not leader"
      raise (TemporarilyUnavailable "not a leader")
    else do
      let (store', rpcErrorOrOutput) = apply input raftState.store
      let log' = appendLog raftState.log [Entry raftState.term input]
      info ("[replication] Log: " <> textShow log')
      putState raftState {store = store', log = log'}
      either raise reply rpcErrorOrOutput

{- | If we're the leader, replicate unacknowledged log entries to followers.
     Also serves as a heartbeat.
-}
replicateLog :: Bool -> Node RaftState Input Output
replicateLog force = do
  now <- getTime
  raftState <- getState
  let elapsedTime = diffTimeMicros now raftState.lastReplication
  when
    ( raftState.role
        == Leader
        && mIN_REPLICATION_INTERVAL_MICROS
        < elapsedTime
    )
    $ do
      nodes <- otherNodeIds
      forM_ nodes $ \node -> do
        let ni = raftState.nextIndex Map.! node
        let entries = fromIndex ni raftState.log
        when (0 < size entries || hEARTBEAT_INTERVAL_MICROS < elapsedTime) $ do
          myNodeId <- getNodeId
          info
            ("[replication] Replicating " <> textShow ni <> " to " <> unNodeId node)
          now <- getTime
          modifyState (\raftState -> raftState {lastReplication = now})
          rpc
            node
            ( AppendEntries
                { term_ = raftState.term
                , leader_id = myNodeId
                , prev_log_index = ni - 1
                , prev_log_term = entryTerm (raftState.log ! (ni - 1))
                , entries = entries
                , leader_commit = raftState.commitIndex
                }
            )
            (info ("[replication] AppendEntries failed to node: " <> unNodeId node))
            $ \res -> do
              case res of
                Right (AppendEntriesOk success term) -> do
                  maybeStepDown term
                  when (raftState.role == Leader && term == raftState.term) $ do
                    resetStepDownDeadline
                    if success
                      then do
                        let nextIndex' = max (raftState.nextIndex Map.! node) (ni + size entries)
                        putState
                          raftState
                            { nextIndex = Map.insert node nextIndex' raftState.nextIndex
                            , matchIndex =
                                Map.insert
                                  node
                                  (max (raftState.matchIndex Map.! node) (ni + size entries - 1))
                                  raftState.matchIndex
                            }
                        info ("[replication] Next index: " <> textShow nextIndex')
                      else do
                        -- We didn't match; back up our next index for this node.
                        putState
                          raftState
                            { nextIndex = Map.adjust pred node raftState.nextIndex
                            }
                _otherwise -> undefined

addMyMatchIndex :: Node RaftState Input Output
addMyMatchIndex = do
  self <- getNodeId
  modifyState
    ( \raftState ->
        raftState
          { matchIndex = Map.insert self (size raftState.log) raftState.matchIndex
          }
    )

becomeCandidate :: Node RaftState Input Output
becomeCandidate = do
  modifyState (\raftState -> raftState {role = Candidate})
  term <- term <$> get
  advanceTerm (term + 1)
  resetElectionDeadline
  resetStepDownDeadline
  info
    ( "[leader election] Become canidate for term " <> fromString (show term)
    )
  requestVotes

becomeFollower :: Node RaftState input output
becomeFollower = do
  term <- term <$> get
  info
    ( "[leader election] Become follower for term " <> fromString (show term)
    )
  modifyState
    ( \raftState ->
        raftState
          { role = Follower
          , matchIndex = Map.empty
          , nextIndex = Map.empty
          }
    )
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
      ( "[leader election] Stepping down: remote term "
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
    (info "[leader election] brpc failed")
    $ \output -> case output of
      Right (RequestVoteRes remoteTerm voteGranted) -> do
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
            info ("[leader election] Have votes: " <> textShow votes')
            myNeighbours <- getPeers
            info
              ( "[leader election] #neighbours: "
                  <> textShow (length myNeighbours)
                  <> ", #votes: "
                  <> textShow (Set.size votes')
              )
            when (majority (length myNeighbours) <= Set.size votes')
              $ do
                info "[leader election] Trying to become leader"
                -- We have a majority of votes for this term!
                becomeLeader

-- What number would constitute a majority of n nodes?
majority :: Int -> Int
majority n = floor (realToFrac n / 2.0 :: Double) + 1

becomeLeader :: Node RaftState Input Output
becomeLeader = do
  role <- role <$> getState
  -- Should be a candidate.
  assertM (role == Candidate)
  now <- getTime
  modifyState
    ( \raftState ->
        raftState
          { role = Leader
          , lastReplication = epoch
          , nextIndex = Map.empty
          , matchIndex = Map.empty
          }
    )
  nodes <- otherNodeIds
  forM_ nodes $ \node -> do
    modifyState
      ( \raftState ->
          raftState
            { nextIndex = Map.insert node (size raftState.log + 1) raftState.nextIndex
            , matchIndex = Map.insert node 0 raftState.matchIndex
            }
      )
  resetStepDownDeadline
  term <- term <$> getState
  info ("[leader election] Become leader for term " <> textShow term)

resetStepDownDeadline :: Node RaftState Input Output
resetStepDownDeadline = do
  now <- getTime
  modifyState
    ( \nodeState ->
        nodeState {stepDownDeadline = addTimeMicros eLECTION_TIMEOUT_MICROS now}
    )
  info
    ( "[leader election] reset stepDownDeadline: "
        <> textShow (addTimeMicros eLECTION_TIMEOUT_MICROS now)
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
