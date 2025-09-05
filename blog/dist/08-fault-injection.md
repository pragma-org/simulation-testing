# Introducing faults to test resilience of a distributed system

*Work in progress, please don't share, but do feel free to get
involved!*

In the previous
[post](https://github.com/pragma-org/simulation-testing/blob/main/blog/dist/07-extending-dsl-with-rpc.md)
we've introduced RPC calls with timeouts. In this post we'll introduce
fault injections, such as partitions and latency, which actually make
the timeouts happen.

## Motivation

One of the main motivations for introducing a distributed system is to
achieve fault tolarance. If the system runs on a single node and that
node fails then the system is unavailable. If on the other hand the
system is distributed across nodes, then it can handle some amound of
nodes failing while still being available and functioning correctly.

That's what we want to ensure in this post, and we'll do so by
simulating failures and see if the system keeps being available and
correct.

## Big picture

                            +------------------------------------------+
                            |                                      SUT |
         +----------+       |   +--------+       +--------+            |
         | Client 1 +------>|   | Node 1 +------>| Node 3 |            |
         |          |<------+   |        |<------+        |            |
         +----------+       |   +-----+--+       +-----+--+            |
               ⋮            |     ^   |             ^  |               |
         +----------+       |     |   v             |  |               |
         | Client N +------>|   +-+------+          |  |               |
         |          |<------+   | Node 2 +----------+  |               |
         +----------+       |   |        |<------------+               |
                            |   +--------+                             |
                            |                                          |
                            +------------------------------------------+

## How it works

- Model links between nodes (and clients?), e.g.

``` haskell
type Network = Map (NodeOrClient, NodeOrClient) Connection

data NodeOrClient = Node NodeId | Client ClientId

data Connection = Link 
  { connected :: Bool
  , baseLatency :: Double
  , jitterLatency :: Double
  , dropProbability :: Double
  , duplicationProbability :: Double
  , reorderProbability :: Double
  }
}
```

- Or closer to Jepsen:

``` haskell
data Fault = PartitionFault Partition
  deriving stock (Show, Read, Eq, Ord)

data Partition
  = None
  | Split SplitKind [NodeId]
  deriving stock (Show, Read, Eq, Ord)

data SplitKind = Single | Majority | Minority | MinorityThird
  deriving stock (Show, Read, Eq, Ord)

affected :: NodeId -> NodeId -> Partition -> Bool
affected src _dest _partition | isClientNodeId src = False
affected src dest (Split _kind nodes) =
  src
    `elem` nodes
    && dest
    `notElem` nodes
    || src
    `notElem` nodes
    && dest
    `elem` nodes
affected _src _dest None = False

```

## Metrics

- In order to get a better feel for what faults are involved it's
  helpful to have the simulator keep track of some metrics about them,
  e.g.:

  1.  how many partitions have been introduced (printing averages like
      partitions per test can also be useful)
  2.  how many messages have been dropped

## Generator

- faults shouldn't be injected before topology messages (in Maelstorm
  init and topology are part of db/node and client setup)

- faults also need to stop before the very end of the test so that the
  system has enough time to recover. The jepsen approach to this problem
  is to generate in phases, something like:

``` haskell
  sequence 
    [ setup -- init/topology in the broadcast case
    , stagger (1 / rate) ops <|> stagger (1/ partition rate) partitions
    , final  -- last round of reads to each node, to ensure that they got all
             -- the broadcasts
    ]
```

Where stagger controls the frequency (arrival time) of the operations.

## Shrinking with partitions

Partitions makes shrinking is a bit more complicated. Consider a simple
broadcasting example with partitions, where there's a bug in the retry
logic of the broadcast:

          broadcast 1 ==> ok
          start partition
          broadcast 2 ==> timeout
          end partition
          broadcast 3 ==> ok
          read ==>  [1,3]
          assertion fails, because [1,3] /= [1,2,3]

The minimal test case is:

          start partition
          broadcast 1 ==> timeout
          end partition
          read ==>  []
          assertion fails, because [] /= [1]

The generator creates broadcasts of monotonically increasing integers
and the property expects that the final reads return the increasing
sequence, so we can't shrink to `broadcast 2` since then the property
will complain that `1` is missing.

But how do we get there?

If we instead had a model where broadcast N pushed N into the model and
read returned all pushed values, then it would work though? Even without
relabelling.

We might want to shrink in a way that perserves the shape of the error?
I.e. `xs /= ys, where xs isSubsetOf ys`. C.f. [Find more bugs with
QuickCheck!](https://smallbone.se/papers/more-bugs.pdf) paper by Hughes
et al (2016).

## Conclusion and what's next

There's a lot more faults that can be introduced and faults can be made
more realistic.

### More faults

#### Crash faults

- Node crashes and restarts (loss of volatile memory). The simulator
  spawns nodes, so implementing crashes and restarts can be done by
  dropping and respawning a node;

- I/O and GC pauses can sometimes be slower than normal due to other
  stuff happening on the computer that the node is running on. One way
  to simulate slow I/O is to implement it as message passing to the
  stable storage, then increasing latency would simulate the I/O pause.

- Time skews (the clock of nodes drifts apart). The simulator controls
  the clock of the nodes, so skews can be implemented by advancing some
  node's clocks more than others;

- Disk failures, to test this the simulator can inject the following
  disk faults on nodes:

  - Delete the whole database;
  - Flip bits in the database;
  - Truncate the write-ahead-log of the database (to simulate a crash
    where the last entry wasn't fully fsynced to disk). For more
    details, see the *Protocol-Aware Recovery for Consensus-Based
    Distributed Storage* paper.

#### Byzantine faults

The space of possibilities here is infinite. Any combination of changing
any message or any piece of state on a faulty node is allowed.
Coordinated attacks (among byzantine nodes) on the protocol level makes
things even more interesting.

### More realistic faults

- Simulate data centers with nodes in them
- Higher latency between data centers than within data centers
- Improvements in fault duration and overlap
- Correlated faults
- More realistic probability distributions for introducing faults
