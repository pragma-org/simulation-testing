# Dealing with the notion of time when simulating distributed systems

*Work in progress, please don't share, but do feel free to get
involved!*

In the previous [post](dist/06-distributed-systems-dsl.md) we
implemented a simple domain-specific language (DSL) for writing
distributed systems where the nodes in the system can read and write to
state as well as send and reply to messages.

In this post we'll extend the DSL with additional features that make it
possible to express more interesting distributed systems. In particular
we'll introduce constructs that deal with time, all while keeping the
event loop of the nodes deterministic.

## Motivation

There's two aspects to consider here. First is being able to talk about
time within our DSL that's used to define the nodes of our system, and
second being able to simulate time in our simulator. Let's deal with
both aspects in turn.

### Why we need notion of time in our node DSL

Without time we can't really do anything interesting. Consider a node
that sends a message, if we don't have the notion of time, how can we
tell that we eventually get a reply? The message might get lost and we
wouldn't be able to tell.

Typically what we want to to start some timer after sending the message
and if that timer fires before we got a reply then we assume that the
message got lost.

Since sending something, setting a timer and waiting for a reply is so
common we shall introduce a non-blocking remote procedure call (RPC)
construct that does all this in one go.

### Why we want to be able to simulate time in the simulator

Regarding being able to simulate time, this is one of the main features
that sets deterministic simulation testing apart from "regular" blackbox
systems testing à la Jepsen[^1].

Without being able to simulate the passage of time we'd need to wait for
our timers to timeout. For example, if we make a RPC and there's a
network partition that makes the call fail, then the regular blackbox
system test would need to wait for that timeout.

With a discrete-event simulator we can avoid the waiting for timeouts by
controlling the clock of the nodes and essentially being able to move
time forward and thus, for example, triggering a timeout without having
to wait.

## Big picture

Let's start by recalling how the simulator interacts with the system
under test (SUT):

              +-------------------------------------+     +-------------------+
              |                           Simulator |     |               SUT |
     Workload |                                     |     |                   |
     -------->| - Heap Time Incoming  +---------+   |     |     +---------+   |
              | - PRNG               ⋰|        ⋰|   |     |    ⋰|        ⋰|   |
              | - History           +---------+ |   |     |   +---------+ |   |
              |                     |   Node  | |   |     |   |   Nodes | |   |
              |                     | Handles |-+ <---------> |         |-+   |
              |                     |         |⋰    |     |   |         |⋰    |
              |                     +---------+     |     |   +---------+     |
              |                                     |     |                   |
              +-------------------------------------+     +-------------------+

The simulation testing process starts by the developer prodiving a
workload, which is comprised of a generator of incoming messages to the
SUT and a property to check. The simulator generates some initial
incoming messages and their arrival times using the generator from the
workload and spawns so called "node handles" (one per node in the SUT).

The node handles are the simulator's API to the SUT which allows it to
perform the test (feed the nodes incoming messages using `handle` and
get outgoing messages back) and control time (via `nextTimer` and
`advancetoTime`) so that we can fast-forward past sleeps and timeouts
(which would slow down the test).

The picture from the node handle's perspective looks like this (we'll
explain the interaction with the node in more detail below):

      +---------------+
      |   Node handle |
      |               |
      |               |
      +-------+-------+
              |
              |   handle        : Time -> Incoming -> [Outgoing]
              |   nextTimer     : Maybe Time
              |   advanceToTime : Time -> [Outgoing] 
              |
              |
      +-------|---------------------------------------------------------------+
      |       v                                                          Node |
      | +-------------+ +-------------------------------------------------+   |
      | |        Shim | |                                   State machine |   |
      | |             | |                                                 |   |
      | |             | | Incoming -> NodeState -> (NodeState, [Effect])  |   |
      | +-----+-------+ +----^-------------------------------+------------+   |
      |       |              |                               |                |
      |       |              |                               |                |
      | +-----v--------------+-------------------------------v-------------+  |
      | |                                                       Event loop |  |
      | | +----------------------------------+                             |  |
      | | |                        Runtime   |     - Pending timers        |  |
      | | |                                  |     - Pending RPCs          |  |
      | | | send    : Outgoing -> ()         |     - Node state            |  |
      | | | receive : Timeout ->             |                             |  |
      | | |           Maybe (Time, Incoming) |                             |  |
      | | |                                  |                             |  |
      | | +----------------------------------+                             |  |
      | |                                                                  |  |
      | +------------------------------------------------------------------+  |
      |                                                                       |
      +-----------------------------------------------------------------------+

We want the node that we test to be as close to the node that we deploy
(in production) as possible. However in real deployments we can't fast
forward time, so `nextTimer` and `advanceToTime` are only part of
simulation testing. A small shim component takes care of this during
simulation. This shim isn't part of the deployed node, but otherwise the
code that gets tested and deployed is identical, with one exception: the
runtime component. During a real deployment, the runtime will be reading
and sending bytes from, for example, a TCP socket. While during
simulation the shim will be writing incoming messages to the runtime,
for it to `receive`, and reading outgoing messages from the runtime,
which it `send`s. Timeouts in `receive` are mocked/faked by use of
`advanceToTime` in order to speed up testing.

The event loop code, which uses the runtime, and the state machine that
gets fed the incoming messages is the same during simulation and real
deployment. The state machine is what our DSL gets interpreted into and
the effects it produces are turned into outgoing messages, for the
runtime to send to approapriate destination, and timers for the event
loop to keep track off.

Hopefully by now we've managed to paint a high-level picture of what's
going on, next let's try to make things more concrete by looking at the
code. We'll look at each of the boxes in the above diagrams separately.

## Extending the DSL

First, let's have a look at what the DSL looks like. The new constructs
are:

- `After`: which sets a timer and runs a provided action when it
  expires;
- `Rpc`: for making an RPC call, takes two continuations, so that it can
  handle both the failure and success case;
- `GetTime`: which returns the current node time;
- `Log`: which is used for logging.

``` haskell

type Node s i o = i -> NodeBody s i o ()

newtype NodeBody s i o a = NodeBody {unNodeBody :: Free (NodeF s i o) a}

```

``` haskell
data NodeF s i o x
  = Reply o (() -> x)
  | Get (NodeState s -> x)
  | Put (NodeState s) (() -> x)
  | Send NodeId i (() -> x)
  | -- NOTE: It can't be `After Int x (() -> x)`, because then the effects of
    -- the continuation (second `x`) will be part of the suspension (first `x`),
    -- I think because of how `iterM` works... Same with Rpc.
    After Int (NodeBody s i o ()) (() -> x)
  | Rpc
      NodeId
      i
      (RpcError -> NodeBody s i o ())
      (o -> NodeBody s i o ())
      (() -> x)
  | GetTime (Time -> x)
  | Log Text (() -> x)
```

The `Get` and `Put` constructs have been generalised slightly, since
last time, to operate over a so called "node state".

``` haskell
data NodeState s = NodeState
  { localState :: s
  , self :: NodeId
  , nodeTime :: Time
  , neighbours :: [NodeId]
  , sender :: NodeId
  , inReplyTo :: MessageId
  }

```

Which contains the "local state" of the node, the node id of itself, the
current time at the node, the neighbour node ids, the node id of the
sender and the in reply to message id of the message we are currently
processing.

``` haskell
initialNodeState :: s -> NodeState s
initialNodeState s =
  NodeState
    { localState = s
    , self = "uninitialised"
    , nodeTime = epoch
    , neighbours = []
    , sender = "uninitialised"
    , inReplyTo = -1
    }

```

## Example: broadcast

To illustrate what this extended DSL is capable of, let's have a look at
an example from Jepsen's
[Maelstrom](https://github.com/jepsen-io/maelstrom): a gossip based
broadcast system.

The broadcast nodes support four messages, initialisation (which
supplies the node with its unique node id and the node ids of its
neighbours), topology (which tells the node which neighbours are
currencly reachable), broadcast (which tells the node to broadcast some
integer to its reachable neighbours) and read (which returns all the
integers that the node has seen):

``` haskell
data BroadcastInput
  = Init {node_id :: NodeId, node_ids :: [NodeId]}
  | Topology {topology :: Map NodeId [NodeId]}
  | Broadcast {message :: Int}
  | Read
```

The responses to the above messages are all simple acknowledgements,
except for the read where we get back a list of integers as just
mentioned:

``` haskell
data BroadcastOutput
  = Init_Ok
  | Topology_Ok
  | Broadcast_Ok
  | Read_Ok {messages :: [Int]}
```

In order to operate as intended the broadcast nodes need to keep track
of integers that they've seen and for each integer, which reachable
neighbours it still needs to broadcast them to:

``` haskell
data BroadcastState = BroadcastState
  { seen :: Set Int
  , unAcked :: Map Int [NodeId]
  }
```

Initially this state starts of being empty.

``` haskell
initialState :: BroadcastState
initialState = BroadcastState Set.empty Map.empty

```

We now got everything we need to define our broadcast nodes:

``` haskell
broadcast :: Node BroadcastState BroadcastInput BroadcastOutput
broadcast (Init self nodeIds) = do
  info
    ( "Initialising: "
        <> unNodeId self
        <> ", neighbours: "
        <> fromString (show nodeIds)
    )
  setSelf self
  setNeighbours nodeIds
  reply Init_Ok
broadcast (Topology nodeIds) = do
  self <- getSelf
  let newNeighbours =
        Map.findWithDefault
          ( error
              ( "self not in topology, self: "
                  <> show self
                  <> ", nodeIds: "
                  <> show nodeIds
              )
          )
          self
          nodeIds
  info ("New neighbours: " <> fromString (show newNeighbours))
  setNeighbours newNeighbours
  reply Topology_Ok
broadcast (Broadcast msg) = do
  sender <- getSender
  info
    ("Acking broadcast " <> textShow msg <> " from " <> textShow sender)
  -- Acknowledge the request.
  reply Broadcast_Ok
  seenMessages <- seen <$> getState
  when (msg `Set.notMember` seenMessages) $ do
    modifyState (\s -> s {seen = Set.insert msg s.seen})
    neighbours <- getNeighbours
    modifyState
      (\s -> s {unAcked = Map.insert msg (neighbours \\ [sender]) s.unAcked})
    let go = do
          unAckedNodes <- (Map.! msg) . unAcked <$> getState
          if null unAckedNodes
            then info ("Done with message: " <> fromString (show msg))
            else do
              info
                ( "Need to replicate \""
                    <> Text.pack (show msg)
                    <> "\" to "
                    <> Text.pack (show unAckedNodes)
                )
              forM_ unAckedNodes $ \nodeId -> do
                info ("Sending RPC to: " <> unNodeId nodeId)
                rpc
                  nodeId
                  (Broadcast msg)
                  ( \rpcError ->
                      info
                        ( "Failed to deliver "
                            <> fromString (show msg)
                            <> " to "
                            <> unNodeId nodeId
                            <> ": "
                            <> fromString (show rpcError)
                        )
                  )
                  ( \case
                      Broadcast_Ok -> do
                        info ("Got ack from: " <> unNodeId nodeId)
                        modifyState
                          (\s -> s {unAcked = Map.adjust (delete nodeId) msg s.unAcked})
                      msg -> error ("broadcast: unexpected response: " <> show msg)
                  )
              s <- getState
              info ("About to sleep, state " <> textShow s)
              after 1_000_000 $ do
                s <- getState
                info ("Awake again, state: " <> textShow s)
                go
    go
broadcast Read = do
  seenMessages <- seen <$> getState
  info ("Read, seen: " <> fromString (show seenMessages))
  reply (Read_Ok (Set.toList seenMessages))

```

All the functions that are used in the broadcast example can be defined
using our DSL, here's for example the functions operating on the node
state:

``` haskell
getState :: NodeBody s i o s
getState = localState <$> generic Get

putState :: s -> NodeBody s i o ()
putState s' = do
  ns <- generic Get
  generic (Put ns {localState = s'})

modifyState :: (s -> s) -> NodeBody s i o ()
modifyState f = do
  s <- getState
  putState (f s)

```

Or the RPC construct:

``` haskell
rpc ::
  NodeId
  -> i
  -> (RpcError -> NodeBody s i o ())
  -> (o -> NodeBody s i o ())
  -> NodeBody s i o ()
rpc nodeId i failure success = generic (Rpc nodeId i failure success)

```

Or logging:

``` haskell
info :: Text -> NodeBody s i o ()
info text = do
  self <- getSelf
  now <- getNodeTime
  generic
    ( Log
        ("[info] (" <> textShow now <> ") [" <> unNodeId self <> "] " <> text)
    )

```

Where a "generic operation"[^2] is defined as:

``` haskell
generic ::
  ( (x -> Free f x)
    -> NodeF state input output (Free (NodeF state input output) a)
  )
  -> NodeBody state input output a
generic op = NodeBody (Free (op Pure))

```

The type of `generic` is complicated, but all it does it wraps some
`op`eration in a node body.

The remaining functions used in the broadcast example follow the same
pattern, and are omitted to save space.

## Semantics

So now we got a language which is expressive enough to describe
interesting distributed systems, but so far it's merely a description.
Next we'll have a look at how we assign meaning to this language in
terms of a simple state machine.

The state machine takes a node state, an input and produces an updated
node state as well as a list of effects:

``` haskell
runNode ::
  Node s i o
  -> NodeState s
  -> i
  -> (NodeState s, [Effect s i o])
runNode node ns i = runNodeBody (node i) (ns, [])

```

Where the effects are the following:

``` haskell
data Effect s i o
  = SEND NodeId i
  | REPLY o
  | RPC NodeId i (RpcError -> Cont s i o) (o -> Cont s i o)
  | LOG Text
  | AFTER Int (Cont s i o)

type Cont s i o =
  (NodeState s, [Effect s i o]) -> (NodeState s, [Effect s i o])

```

And running the body of a node is defined as following:

``` haskell
runNodeBody ::
  forall s i o a.
  NodeBody s i o a
  -> (NodeState s, [Effect s i o])
  -> (NodeState s, [Effect s i o])
runNodeBody (NodeBody m) = iterM go done m
  where
    done ::
      a -> (NodeState s, [Effect s i o]) -> (NodeState s, [Effect s i o])
    done _x (ns, effects) = (ns, effects)

    go ::
      Alg
        (NodeF s i o)
        ((NodeState s, [Effect s i o]) -> (NodeState s, [Effect s i o]))
    go (Reply o k) (ns, acc) = k () (ns, acc <> [REPLY o])
    go (Send nodeId i k) (ns, acc) = k () (ns, acc <> [SEND nodeId i])
    go (Get k) (s, acc) = k s (s, acc)
    go (Put s' k) (s, acc) = k () (s', acc)
    go (Rpc nodeId i failure success k) (ns, acc) =
      k
        ()
        ( ns
        , acc
            <> [ RPC
                  nodeId
                  i
                  (\rpcError -> runNodeBody (failure rpcError))
                  (\o -> runNodeBody (success o))
               ]
        )
    go (Log text k) (ns, acc) = k () (ns, acc <> [LOG text])
    go (GetTime k) (ns, acc) = k ns.nodeTime (ns, acc)
    go (After micros m k) (ns, acc) =
      k () (ns, acc <> [AFTER micros (runNodeBody m)])
```

## Event loop

We've now got a state machine which advances the node state given an
input and produces effects, next we'll define an event loop which drives
our state machine.

For the event loop to be able to do its job, it needs a bit of state:

``` haskell
data EventLoopState s i o = EventLoopState
  { nextMessageId :: MessageId
  , pendingRpcs :: Map MessageId (o -> Cont s i o)
  , pendingTimers ::
      TimerWheel Time (Maybe MessageId, Cont s i o)
  }

initialEventLoopState :: EventLoopState s i o
initialEventLoopState =
  EventLoopState
    { nextMessageId = 0
    , pendingRpcs = Map.empty
    , pendingTimers = emptyTimerWheel
    }

```

The next message id will be used to identify all outgoing messages (this
is needed in case we get a reply, so that we can correlated the reply
with the original message). The pending RPCs field holds the
success-continuations of RPCs that the node has sent (in a map keyed by
the message id of the original message). The pending timers field holds
RPC timeouts as well as other timers that the node has set for itself.

The event loop takes a node, it's initial local state, a codec (which
decodes and encodes incoming and outgoing messages) and a runtime (which
receives incoming messages and deals with the effects produced by the
node).

``` haskell
eventLoop ::
  forall m s i_ i o_ o.
  (Show s, Show i_, Show i, Show o, Show o_) =>
  (Monad m, MonadMask m) =>
  Node s i o
  -> s
  -> Codec i_ i o_ o
  -> Runtime m i_ o_
  -> m ()
eventLoop node initialState codec runtime =
  loop (initialNodeState initialState) initialEventLoopState
    `finally` runtime.close
  where
    loop :: NodeState s -> EventLoopState s i o -> m ()
    loop ns es = do
      (ns', es') <- stepEventLoop node codec runtime ns es
      loop ns' es'

```

At each step of the event loop, we first check if there are any pending
timers. If there are no pending timers, we start waiting for an incoming
message by receiving via the runtime. A receive operation takes a
timeout value in microseconds as a parameter, and if no incoming message
is receieved within that time it will return `Nothing`, otherwise it
returns the the incoming message and its arrival time.

It gets more interesting when there's a pending timer. In that case we
receieve with a timeout which is the difference of what the time is now
and when the timer goes off, meaning that if we haven't receieved any
incoming message by the time that the timer goes off we'll get back
`Nothing` and can proceed with handling the timer.

``` haskell
stepEventLoop ::
  forall m s i_ i o_ o.
  (Show s, Show i_, Show i, Show o, Show o_) =>
  (Monad m) =>
  Node s i o
  -> Codec i_ i o_ o
  -> Runtime m i_ o_
  -> NodeState s
  -> EventLoopState s i o
  -> m (NodeState s, EventLoopState s i o)
stepEventLoop node codec runtime ns es =
  case popTimer es.pendingTimers of
    Nothing -> do
      runtime.receive 20_000_000 >>= \case
        Nothing -> do
          -- NOTE: This `send` is needed for simulation handle, otherwise
          -- the call to `takeMVar outputMVar` in simulationNodeHandle.handle
          -- times out.
          runtime.send []
          return (ns, es)
        Just (arrivalTime, incoming) -> do
          (ns', es', outgoing) <-
            handleIncoming
              node
              codec
              runtime
              ns {nodeTime = arrivalTime}
              es
              incoming
          runtime.send outgoing
          return (ns', es')
    Just ((later, (mMessageId, k)), pendingTimers') -> do
      let now = ns.nodeTime
      -- NOTE: The `max 0` is needed because if we pass a negative value to
      -- `timeout` it won't timeout.
      let micros = max 0 (diffTimeMicros later now)
      runtime.receive micros >>= \case
        Nothing -> do
          -- We didn't receive a message within `micros`, and therefore need to
          -- handle the timer.
          let now = ns.nodeTime
          let (ns', effects) = k (ns {nodeTime = now}, [])
          (es', outgoing) <-
            handleEffects
              runtime
              codec
              ns'
              es {pendingTimers = pendingTimers'}
              effects
          runtime.send outgoing
          return (ns', es')
        Just (arrivalTime, incoming) -> do
          (ns', es', outgoing) <-
            handleIncoming
              node
              codec
              runtime
              ns {nodeTime = arrivalTime}
              es
              incoming
          runtime.send outgoing
          return (ns', es')

```

The above code just takes one step in the event loop, to actually run
the event loop we loop the step function as follows:

``` haskell
eventLoop ::
  forall m s i_ i o_ o.
  (Show s, Show i_, Show i, Show o, Show o_) =>
  (Monad m, MonadMask m) =>
  Node s i o
  -> s
  -> Codec i_ i o_ o
  -> Runtime m i_ o_
  -> m ()
eventLoop node initialState codec runtime =
  loop (initialNodeState initialState) initialEventLoopState
    `finally` runtime.close
  where
    loop :: NodeState s -> EventLoopState s i o -> m ()
    loop ns es = do
      (ns', es') <- stepEventLoop node codec runtime ns es
      loop ns' es'

```

The above code contains four pieces which we haven't seen yet:

- `Codec`: for encoding and decoding messages;
- `handleIncoming`: for handling incoming messages;
- `handleEffects`: for handing the effects that our node produces when
  it processes an incoming message.
- `Runtime`: which is used for receiving and sending messages and
  logging.

Let's have a look at each of these in turn.

## Messages and their codec

``` haskell
data Codec i_ i o_ o = Codec
  { decodeIncoming :: i_ -> Either String (Incoming i o)
  , encodeOutgoing :: Outgoing i o -> o_
  }

```

``` haskell
data Incoming i o
  = InMessage (Message i)
  | InResponse (Response o)
  | InRpcError RpcError
```

``` haskell
data Outgoing i o
  = OutMessage (Message i)
  | OutResponse (Response o)
  | OutRpcError RpcError
```

``` haskell
data Message i = Message
  { src :: NodeId
  , dest :: NodeId
  , msgId :: Maybe MessageId
  , body :: i
  }
```

``` haskell
data Response o = Response
  { src :: NodeId
  , dest :: NodeId
  , msgId :: Maybe MessageId
  , inReplyTo :: MessageId
  , body :: o
  }
```

``` haskell
data RpcError = Timeout
```

## Handling incoming messages and effects

``` haskell
handleIncoming ::
  forall m s i_ i o_ o.
  (Show s, Show i_, Show i, Show o) =>
  (Monad m) =>
  Node s i o
  -> Codec i_ i o_ o
  -> Runtime m i_ o_
  -> NodeState s
  -> EventLoopState s i o
  -> [i_]
  -> m (NodeState s, EventLoopState s i o, [o_])
handleIncoming node codec runtime = go []
  where
    go ::
      [[o_]]
      -> NodeState s
      -> EventLoopState s i o
      -> [i_]
      -> m (NodeState s, EventLoopState s i o, [o_])
    go acc ns es [] = return (ns, es, concatMap reverse acc)
    go acc ns es (i_ : incoming) = do
      case codec.decodeIncoming i_ of
        Left err -> do
          runtime.log
            ( Text.pack
                ( "Failed to parse input: "
                    <> err
                    <> "\nbody: "
                    <> show i_
                    <> "\npendingRpcs: "
                    <> show (Map.keys es.pendingRpcs)
                )
            )
          go acc ns es incoming
        Right (InMessage message) -> do
          let now = ns.nodeTime
          let (ns', effects) =
                runNode
                  node
                  ns
                    { sender = message.src
                    , inReplyTo = case message.msgId of
                        Nothing ->
                          error
                            ("handleIncoming: message doesn't have msgId set: " <> show message)
                        Just msgId -> msgId
                    , nodeTime = now
                    }
                  message.body
          -- hPutStrLn stderr ("InMessage, effects: " <> show effects)
          (es', outgoing) <- handleEffects runtime codec ns' es effects
          go (outgoing : acc) ns' es' incoming
        Right (InResponse response) ->
          case Map.lookup response.inReplyTo es.pendingRpcs of
            Nothing -> undefined
            Just k -> do
              let now = ns.nodeTime
              -- hPutStrLn stderr ("Resuming success with state: " <> show ns.localState)
              let (ns', effects) = k response.body (ns {nodeTime = now}, [])
              -- hPutStrLn stderr ("InResponse, effects: " <> show effects)
              let es' =
                    es
                      { pendingRpcs = Map.delete response.inReplyTo (pendingRpcs es)
                      , pendingTimers =
                          filterTimer ((/= Just response.inReplyTo) . fst) (pendingTimers es)
                      }
              (es'', outgoing) <-
                handleEffects
                  runtime
                  codec
                  ns' {sender = response.src}
                  es'
                  effects
              go (outgoing : acc) ns' es'' incoming
        Right InRpcError {} -> undefined

```

``` haskell
handleEffects ::
  forall m i i_ o o_ s.
  (Monad m) =>
  Runtime m i_ o_
  -> Codec i_ i o_ o
  -> NodeState s
  -> EventLoopState s i o
  -> [Effect s i o]
  -> m (EventLoopState s i o, [o_])
handleEffects runtime codec ns = go []
  where
    go ::
      [o_]
      -> EventLoopState s i o
      -> [Effect s i o]
      -> m (EventLoopState s i o, [o_])
    go acc es [] = return (es, acc)
    go acc es (SEND nodeId i : effects) = do
      let messageId = es.nextMessageId
      let outgoing =
            OutMessage
              $ Message
                { src = ns.self
                , dest = nodeId
                , msgId = Just messageId
                , body = i
                }
      go
        (codec.encodeOutgoing outgoing : acc)
        es {nextMessageId = messageId + 1}
        effects
    go acc es (REPLY o : effects) = do
      let messageId = es.nextMessageId
      let outgoing =
            OutResponse
              $ Response
                { src = ns.self
                , dest = ns.sender
                , msgId = Just messageId
                , inReplyTo = ns.inReplyTo
                , body = o
                }
      go
        (codec.encodeOutgoing outgoing : acc)
        es {nextMessageId = messageId + 1}
        effects
    go acc es (RPC nodeId i failure success : effects) = do
      let messageId = es.nextMessageId
      let outgoing =
            OutMessage
              $ Message
                { src = ns.self
                , dest = nodeId
                , msgId = Just messageId
                , body = i
                }
      let now = ns.nodeTime
      let es' =
            es
              { nextMessageId = messageId + 1
              , pendingRpcs = Map.insert messageId success (pendingRpcs es)
              , pendingTimers =
                  insertTimer
                    (addTimeMicros rPC_TIMEOUT_MICROS now)
                    (Just messageId, failure Timeout)
                    es.pendingTimers
              }
      go (codec.encodeOutgoing outgoing : acc) es' effects
    go acc es (LOG text : effects) = do
      runtime.log text
      go acc es effects
    go acc es (AFTER micros k : effects) = do
      let now = ns.nodeTime
      let es' =
            es
              { pendingTimers =
                  insertTimer
                    (addTimeMicros micros now)
                    (Nothing, k)
                    es.pendingTimers
              }
      -- Text.hPutStrLn stderr
      --   $ "INSERTED TIMER AT: "
      --   <> textShow (addTimeMicros micros now)
      --   <> ", pendingTimers: "
      --   <> textShow (map (fmap fst) (toListTimer es'.pendingTimers))
      go acc es' effects

rPC_TIMEOUT_MICROS :: Int
rPC_TIMEOUT_MICROS = 5_000_000 -- 5s.
```

## Runtime

All the side-effects made by the event loop come from the so called
runtime.

``` haskell
type Timeout = Int

data Runtime m i o = Runtime
  { receive :: Timeout -> m (Maybe (Time, [i]))
  , send :: [o] -> m ()
  , log :: Text -> m ()
  , close :: m ()
  }

```

The reason for this interface is so that we can use different instances
of it during simulation testing and real deployment, without having to
otherwise change the event loop code.

For example where's a runtime that recieves messages on `stdin`, sends
messages on `stdout` and does logging on `stderr` (this is how Maelstrom
talks to the SUT it's testing).

``` haskell
consoleRuntime :: IO (Runtime IO ByteString ByteString)
consoleRuntime = do
  hSetBuffering stdin LineBuffering
  hSetBuffering stdout LineBuffering
  hSetBuffering stderr LineBuffering
  return
    Runtime
      { receive = \micros -> Timeout.timeout micros consoleReceive
      , send = consoleSend
      , log = Text.hPutStrLn stderr
      , close = return ()
      }
  where
    consoleReceive :: IO (Time, [ByteString])
    consoleReceive = do
      line <- BS8.hGetLine stdin
      if BS8.null line
        then return (epoch, []) -- XXX: epoch?
        else do
          BS8.hPutStrLn stderr ("consoleRuntime: received: " <> line)
          arrivalTime <- getCurrentTime
          return (arrivalTime, [line])

    consoleSend :: [ByteString] -> IO ()
    consoleSend = mapM_ $ \bytes -> do
      BS8.hPutStrLn stderr ("consoleRuntime: sent: " <> bytes)
      BS8.hPutStrLn stdout bytes

```

Another instance of the runtime interface is the simultion runtime,
which is used during simulation testing. This is the box called "shim"
in the diagrams from the overview.

``` haskell
data SimulationCommand i o
  = Handle Time (Incoming i o)
  | NextTimer
  | AdvanceToTime Time
  deriving stock (Show, Read)

data SimulationResponse i o
  = HandleResponse [Outgoing i o]
  | NextTimerResponse (Maybe Time)
  | AdvanceToTimeResponse [Outgoing i o]
  deriving stock (Show, Read)

simulationRuntime ::
  MVar (Time, Incoming i o)
  -> MVar [Outgoing i o]
  -> IO (Runtime IO (Incoming i o) (Outgoing i o))
simulationRuntime inputMVar outputMVar = do
  return
    Runtime
      { send = putMVar outputMVar
      , receive = \timeout -> case timeout of
          0 -> return Nothing
          _ -> do
            (arrivalTime, incoming) <- takeMVar inputMVar
            -- now <- readFaketime
            -- assert (now - arrivalTime == 0)
            return (Just (arrivalTime, [incoming]))
      , log = Text.hPutStrLn stderr
      , close = return ()
      }

-- AKA shim
simulationEventLoop ::
  forall s i o.
  (Show s, Show i, Show o, Read i, Read o) =>
  Node s i o
  -> s
  -> IO ()
simulationEventLoop node initialState = do
  inputMVar <- newEmptyMVar
  outputMVar <- newEmptyMVar
  runtime <- simulationRuntime inputMVar outputMVar
  hSetBuffering stdin LineBuffering
  hSetBuffering stdout LineBuffering
  hSetBuffering stderr LineBuffering
  loop
    inputMVar
    outputMVar
    runtime
    (initialNodeState initialState)
    initialEventLoopState
    `finally` runtime.close
  where
    loop ::
      MVar (Time, Incoming i o)
      -> MVar [Outgoing i o]
      -> Runtime IO (Incoming i o) (Outgoing i o)
      -> NodeState s
      -> EventLoopState s i o
      -> IO ()
    loop inputMVar outputMVar runtime ns es = do
      line <- hGetLine stdin
      case readEither line of
        Right (Handle arrivalTime incoming) -> do
          putMVar inputMVar (arrivalTime, incoming)
          (ns', es') <-
            stepEventLoop node testCodec runtime ns {nodeTime = arrivalTime} es
          outgoing <- takeMVar outputMVar
          hPutStrLn
            stdout
            (show (HandleResponse outgoing))
          loop inputMVar outputMVar runtime ns' es'
        Right NextTimer -> do
          let mNextTimer = TimerWheel.nextTimer es.pendingTimers
          hPutStrLn
            stdout
            (show (NextTimerResponse mNextTimer :: SimulationResponse i o))
          loop inputMVar outputMVar runtime ns es
        Right (AdvanceToTime newTime) -> do
          (ns', es') <-
            stepEventLoop node testCodec runtime ns {nodeTime = newTime} es
          outgoing <- takeMVar outputMVar
          hPutStrLn
            stdout
            (show (AdvanceToTimeResponse outgoing))
          loop inputMVar outputMVar runtime ns' es'
        Left err -> error ("simulationEventLoop, failed to parse input: " <> err)

```

Like the console runtime used by Maelstrom we use `stdin` and `stdout`,
but since simulation requires control over time we've extended the
Maelstrom "protocol" to also be able to get the next timer that a node
is waiting for as well as advance the time.

For a real deployment the runtime would use, for example, a TCP socket
to do the receiving and sending of messages and perhaps the signature
would be something like the following.

``` haskell
tcpRuntime ::
  Port -> Map NodeId Port -> IO (Runtime IO ByteString ByteString)
```

## Node handle

The so called node handle, which is spawned by the simulator and allows
it to communicate with the SUT, needs to be extended to also be able to
ask for the next timer and advance the time.

``` haskell
data NodeHandle i o = NodeHandle
  { handle :: Time -> Incoming i o -> IO (HandleOutput i o)
  , nextTimer :: IO (Maybe Time)
  , advanceToTime :: Time -> IO (HandleOutput i o)
  , close :: IO ()
  }

```

``` haskell
data HandleOutput i o = HandleOutput
  { outgoing :: [Outgoing i o]
  }

noHandleOutput :: HandleOutput i o
noHandleOutput =
  HandleOutput
    { outgoing = []
    }

```

``` haskell
simulationNodeHandle ::
  forall s i o.
  (Show i, Read i, Show o, Read o) =>
  FilePath
  -> [String]
  -> IO (NodeHandle i o)
simulationNodeHandle binaryFilePath arguments = do
  (Just hin, Just hout, _, processHandle) <-
    createProcess
      (proc binaryFilePath arguments)
        { std_in = CreatePipe
        , std_out = CreatePipe
        }
  hSetBuffering hin LineBuffering
  hSetBuffering hout LineBuffering
  hSetBuffering stderr LineBuffering
  return
    NodeHandle
      { handle = \arrivalTime incoming -> do
          hPutStrLn hin (show (Handle arrivalTime incoming))
          hFlush hin
          line <- hGetLine hout
          case readEither line :: Either String (SimulationResponse i o) of
            Right (HandleResponse outgoing) ->
              return
                HandleOutput {beforeState = "", afterState = "", outgoing, logs = []}
            Right _ -> error "simulationNodeHandle, impossible, bad response"
            Left err -> do
              hPutStrLn stderr err
              return noHandleOutput
      , nextTimer = do
          hPutStrLn hin (show (NextTimer :: SimulationCommand i o))
          hFlush hin
          line <- hGetLine hout
          case readEither line :: Either String (SimulationResponse i o) of
            Right (NextTimerResponse mTime) -> return mTime
            Right _ -> error "simulationNodeHandle, impossible, bad response"
            Left err -> error ("simulationNodeHandle, nextTimer error: " <> err)
      , advanceToTime = \newTime -> do
          hPutStrLn hin (show (AdvanceToTime newTime :: SimulationCommand i o))
          hFlush hin
          line <- hGetLine hout
          case readEither line :: Either String (SimulationResponse i o) of
            Right (AdvanceToTimeResponse outgoing) ->
              return
                HandleOutput {beforeState = "", afterState = "", outgoing, logs = []}
            Right _ -> error "simulationNodeHandle, impossible, bad response"
            Left err -> error ("simulationNodeHandle, advanceToTime error: " <> err)
      , close = terminateProcess processHandle
      }

```

## Changes to the simulator

We've already had a look at how to write the simulator component in a
[previous](https://github.com/pragma-org/simulation-testing/blob/main/blog/dist/04-simulation-testing-main-loop.md)
post, so we'll try to not repeat ourselves unnecessarily and merely look
at what has to be changed in order to simulate time.

Recall that the job of the simulator is to generate test cases using the
workload, then simulate the "world" for each test case, which finally
results in a history of client requests and responses from the SUT,
which then the property is checked against.

The only part that needs to be changed is the step world function:

``` haskell

data StepSuccess i o
  = StepDone
  | StepContinue (World i o)

data StepFailure
  = StepSomeException SomeException
  | StepUnknownDestination NodeId
  | StepTimeoutWhenHandling String
  | StepTooManySteps

data StepResult i o
  = StepFailure StepFailure
  | StepSuccess (StepSuccess i o)

stepWorld ::
  (Show i, Show o, Ord i, Ord o) => World i o -> IO (StepResult i o)
stepWorld world = do
  case Heap.pop world.messages of
    Nothing -> return (StepSuccess StepDone)
    Just ((arrivalTime, incoming), messages') -> do
      case incoming of
        InTimer nodeId -> case Map.lookup nodeId world.nodes of
          Nothing ->
            return
              ( StepFailure
                  (StepUnknownDestination nodeId)
              )
          Just nodeHandle -> do
            handleOutput <- nodeHandle.advanceToTime arrivalTime
            mTime <- nodeHandle.nextTimer
            let (clientResponses, nodeMessages) =
                  List.partition (isClientNodeId . (.dest)) handleOutput.outgoing
            -- XXX: Make this configurable via workload?
            let meanMicros = 200_000 -- 200ms
            let ((nodeMessages', _time), prng') =
                  generateRandomArrivalTimes
                    arrivalTime
                    meanMicros
                    (map outgoingToIncoming nodeMessages)
                    world.prng
            return
              $ StepSuccess
              $ StepContinue
                World
                  { nodes = world.nodes
                  , messages =
                      -- NOTE: only add timer event if there already isn't one.
                      messages'
                        `Heap.union` Heap.fromList
                          ( (map (\time -> (time, InTimer nodeId)) (maybeToList mTime))
                              ++ nodeMessages'
                          )
                  , prng = prng'
                  , -- XXX: the arrival time for client responses is arbitrary
                    history =
                      world.history
                        ++ map
                          ( \clientResponse -> (addTimeMicros (round meanMicros) arrivalTime, clientResponse)
                          )
                          clientResponses
                  }
        _otherwise ->
          case Map.lookup incoming.dest world.nodes of
            Nothing ->
              return
                ( StepFailure
                    (StepUnknownDestination incoming.dest)
                )
            Just nodeHandle ->
              timeout 5_000_000 (try (nodeHandle.handle arrivalTime incoming)) >>= \case
                Nothing ->
                  return
                    ( StepFailure
                        (StepTimeoutWhenHandling (show incoming))
                    )
                Just (Left err) -> do
                  putStrLn
                    ( "stepWorld, failed on: "
                        <> show (arrivalTime, incoming, messages')
                    )
                  return (StepFailure (StepSomeException err))
                Just (Right handleOutput) -> do
                  -- mapM_ Text.putStrLn handleOutput.logs
                  let (clientResponses, nodeMessages) =
                        List.partition (isClientNodeId . (.dest)) handleOutput.outgoing
                  let meanMicros = 20000 -- 20ms
                  let ((nodeMessages', _time), prng') =
                        generateRandomArrivalTimes
                          arrivalTime
                          meanMicros
                          (map outgoingToIncoming nodeMessages)
                          world.prng
                  mTime <- nodeHandle.nextTimer
                  -- XXX: code duplication from above...
                  return
                    $ StepSuccess
                    $ StepContinue
                      World
                        { nodes = world.nodes
                        , messages =
                            messages'
                              `Heap.union` Heap.fromList
                                ( (map (\time -> (time, InTimer incoming.dest)) (maybeToList mTime))
                                    ++ nodeMessages'
                                )
                        , prng = prng'
                        , -- XXX: the arrival time for client responses is arbitrary
                          history =
                            world.history ++ (arrivalTime, incomingToOutgoing incoming)
                              : map
                                ( \clientResponse -> (addTimeMicros (round meanMicros) arrivalTime, clientResponse)
                                )
                                clientResponses
                        }

```

Notice how the heap now contains incoming messages as well as timers,
and how we check what the next timer is and merge the timer events into
the heap.

## Example: Maelstrom and simulation testing broadcast

The final thing left to do is to run our example. We can run it in two
ways:

1.  Using the console runtime, which allows us to blackbox test it with
    Maelstrom;
2.  Using the simulation runtime, which allows us to simulation test it
    with the simulator.

Let's start with the console runtime:

``` haskell
libMain :: IO ()
libMain = do
  runtime <- consoleRuntime
  eventLoop broadcast initialState jsonCodec runtime

```

If we let this be the `main` and compile a binary out of it, we can then
test it with Maelstrom as follows:

``` bash
./maelstrom test -w broadcast --bin $(cabal list-bin broadcast) --time-limit 5 --log-stderr --rate 10

[...]

INFO [2025-08-27 13:25:25,136] jepsen test runner - jepsen.core {:perf {:latency-graph {:valid? true},
        :rate-graph {:valid? true},
        :valid? true},
 :timeline {:valid? true},
 :exceptions {:valid? true},
 :stats {:valid? true,
         :count 54,
         :ok-count 54,
         :fail-count 0,
         :info-count 0,
         :by-f {:broadcast {:valid? true,
                            :count 22,
                            :ok-count 22,
                            :fail-count 0,
                            :info-count 0},
                :read {:valid? true,
                       :count 32,
                       :ok-count 32,
                       :fail-count 0,
                       :info-count 0}}},
 :availability {:valid? true, :ok-fraction 1.0},
 :net {:all {:send-count 392,
             :recv-count 392,
             :msg-count 392,
             :msgs-per-op 7.259259},
       :clients {:send-count 128, :recv-count 128, :msg-count 128},
       :servers {:send-count 264,
                 :recv-count 264,
                 :msg-count 264,
                 :msgs-per-op 4.888889},
       :valid? true},
 :workload {:worst-stale (),
            :duplicated-count 0,
            :valid? true,
            :lost-count 0,
            :lost (),
            :stable-count 22,
            :stale-count 0,
            :stale (),
            :never-read-count 0,
            :stable-latencies {0 0, 0.5 0, 0.95 0, 0.99 0, 1 0},
            :attempt-count 22,
            :never-read (),
            :duplicated {}},
 :valid? true}

Everything looks good! ヽ(‘ー`)ノ
```

For simulation testing we instead stick the following into the `main`
function and compile a binary. This is almost the same as the above,
with the exception of the shim which allows the simulator to query the
next timer and advance time.

``` haskell
simulationLibMain :: IO ()
simulationLibMain = simulationEventLoop broadcast initialState

```

We can then use this binary when calling our simulator from the REPL as
follows:

    >>> let config = defaultTestConfig { numberOfTests = 10 }
    >>> binary <- filter (/= '\n') <$> readProcess "cabal" ["list-bin", "broadcast-simulation"] ""
    >>> outOfProcessSimulationTestWith config binary [] (broadcastWorkload config)

    [...]

    Metrics {droppedMessages = 424, partitions = 55, numberOfTests = 10}

    Success!

Where out-of-process simulation testing is defined as follows:

``` haskell
outOfProcessSimulationTestWith ::
  ( Show input
  , Show output
  , Read input
  , Read output
  , Ord input
  , Ord output
  ) =>
  TestConfig
  -> FilePath
  -> [String]
  -> Workload input output
  -> IO Bool
outOfProcessSimulationTestWith testConfig binaryFilePath arguments workload = do
  (prng, seed) <- newPrng testConfig.replaySeed
  let deployment =
        Deployment
          { numberOfNodes = testConfig.numberOfNodes
          , spawn = simulationNodeHandle binaryFilePath arguments
          }
  result <- runTests testConfig deployment workload prng
  handleResult result seed

```

For completeness we should also mention that it's possible to write an
in-process simulator, which uses a node handle which doesn't spawn an
external process but rather calls `stepEventLoop` in the same thread as
the simulator. This only works if the SUT is written in the same
language as the simulator though, so what we showed above is more
general albeit probably a bit slower due to the serialisation overhead.

## Discussion: the gap between simulation and reality

We want the difference between what we simulate and deploy to be as
small as possible, in order to be able to catch as many bugs as possible
during simulation testing.

Because of this we've tried to design for as much reuse as possible,
however there are a few notable gaps which we worth mentioning.

We've already talked about the "shim" component which allows us to speed
up the passage of time in the event loop. This code is only part of the
simulation and is not being deployed.

The code for the shim itself is pretty short, and unlikely to contain
any major bugs, however there's a risk that the way we handle time is
too simplicit. In particular we take a very discrete approach and don't
simulate parallel execution of nodes. The argument here is that it
should be fine as nodes don't share data anyway.

Apart from the shim component, the other difference between simulation
and what's being deployed is the runtime interface instance. During
simulation testing the runtime receives and sends messages using `MVar`s
via the shim, whereas when deployed the runtime will be using TCP
sockets instead. Arguebly receieving and sending messages is a narrow
interface, with little room for bugs to sneak in, however the TCP
runtime itself (which we haven't implemented yet) is a non-trivial piece
of code and should therefore be tested carefully on its own.

One could also imagine doing the simulation with real TCP connections to
the nodes, this would increase the code overlap between simulation and
what's being deployed, however it would also add overhead compared to
the in-memory approach. The simulator would have to be extended in order
to simulate realisitic concurrent TCP connections, and overall it's not
clear if all of this is worth the effort.

One last thing worth mentioning here is that in the current in-memory
runtime approach, the codec isn't used, so using a more realistic
runtime could also exersise these code paths during simulation. However
testing the codec separately using a round-trip property is likely good
enough.

- Code paths in stepEventLoop that are never taken in simulation?

  - add asserts to confirm?

- In the node DSL if we do t1 \<- getTime, t2 \<- getTime then t1 == t2
  as time doesn't move during a step

  - Alternative: We could make getTime into an effect which would
    suspend and get a callback once runtime.getTime finishes

- XXX: use profiler to check?

- XXX: can we use a faketime version of timeout to have a smaller gap?

## Conclusion and what's next

We've added constructs to our DSL for dealing with time, a key part of
distributed systems, and made the simulator able to fake the passage of
time in order to speed up testing involving timers.

The next step would be to add fault injection, e.g. network partitions
or latency, which would trigger timeout timers associated with RPC
requests which in turn would cause retries. This will ensure that our
nodes are robust in the presence of failures.

Another possible improvement is to extend the DSL to allow synchronous
(or blocking) RPC calls, which would make it easier to express some use
cases (e.g. the Datomic transactor
[example](https://github.com/jepsen-io/maelstrom/blob/main/doc/05-datomic/index.md)
from Maelstrom).

[^1]: The other main feature that sets deterministic simulation testing
    apart from Jepsen is the fact that the tests are deterministic and
    failures can be reproduced from a seed.

[^2]: Generic operation is Plotkin and Power's terminology from their
    work on algebraic effects.
