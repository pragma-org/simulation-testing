---
author: Stevan A
date: 2025-09-02
status: sketch
---

# Introducing faults to test resilience of a distributed system

*Work in progress, please don't share, but do feel free to get involved!*

In the previous
[post](https://github.com/pragma-org/simulation-testing/blob/main/blog/dist/07-extending-dsl-with-rpc.md)
we've introduced RPC calls with timeouts. In this post we'll introduce fault
injections, such as partitions and latency, which actually make the timeouts
happen.

## Motivation

## Big picture

* Model links between nodes (and clients?), e.g.

```haskell
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

* Or closer to Jepsen:

```haskell
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

* In order to get a better feel for what faults are involved it's helpful to
  have the simulator keep track of some metrics about them, e.g.:

  1. how many partitions have been introduced (printing averages like
     partitions per test can also be useful)
  2. how many messages have been dropped

## Generator

+ faults shouldn't be injected before topology messages (in Maelstorm init
  and topology are part of db/node and client setup)

+ overlapping faults? (not needed yet)

+ What we want is:
  phases `sequence [ setup, stagger (1 / rate) ops | stagger (1/ partition
  rate) partitions, final ]`?

## Shrinking with partitions

Partitions makes shrinking is a bit more complicated. Consider a simple
broadcasting example with partitions, where there's a bug in the retry logic of
the broadcast:

```
      broadcast 1 ==> ok
      start partition
      broadcast 2 ==> timeout
      end partition
      broadcast 3 ==> ok
      read ==>  [1,3]
      assertion fails, because [1,3] /= [1,2,3]
```

The minimal test case is:

```
      start partition
      broadcast 1 ==> timeout
      end partition
      read ==>  []
      assertion fails, because [] /= [1]
```

The generator creates broadcasts of monotonically increasing integers and the
property expects that the final reads return the increasing sequence, so we
can't shrink to `broadcast 2` since then the property will complain that `1` is
missing.

But how do we get there?

If we instead had a model where broadcast N pushed N into the model and read
returned all pushed values, then it would work though? Even without
relabelling.

We might want to shrink in a way that perserves the shape of the error? I.e.
`xs /= ys, where xs isSubsetOf ys`. C.f. [Find more bugs with
QuickCheck!](https://smallbone.se/papers/more-bugs.pdf) paper by Hughes et al
(2016).

## Conclusion and what's next



