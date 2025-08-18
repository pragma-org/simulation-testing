---
author: Stevan A
date: 2025-08-13
status: sketch
---

# Dealing with the notion of time when simulating distributed systems

*Work in progress, please don't share, but do feel free to get involved!*

In the previous [post](dist/06-distributed-systems-dsl.md) we implemented a
simple domain-specific language (DSL) for writing distributed systems where the
nodes in the system can read and write to state as well as send and reply to
messages.

In this post we'll extend the DSL with additional features that make it
possible to express more interesting distributed systems. In particular we'll
introduce constructs that deal with time, all while keeping the event loop of
the nodes deterministic.

## Motivation

There's two aspects to consider here. First is being able to talk about time
within our DSL that's used to define the nodes of our system, and second being
able to simulate time in our simulator. Let's deal with both aspects in turn.

### Why we need notion of time in our node DSL

Without time we can't really do anything interesting. Consider a node that
sends a message, if we don't have the notion of time, how can we tell that we
eventually get a reply? The message might get lost and we wouldn't be able to
tell.

Typically what we want to to start some timer after sending the message and if
that timer fires before we got a reply then we assume that the message got
lost.

Since sending something, setting a timer and waiting for a reply is so common
we shall introduce a non-blocking remote procedure call (RPC) construct that
does all this in one go.

### Why we want to be able to simulate time in the simulator

Regarding being able to simulate time, this is one of the main features that
sets deterministic simulation testing apart from "regular" blackbox systems
testing à la Jepsen[^1].

Without being able to simulate the passage of time we'd need to wait for our
timers to timeout. For example, if we make a RPC and there's a network
partition that makes the call fail, then the regular blackbox system test would
need to wait for that timeout.

With a discrete-event simulator we can avoid the waiting for timeouts by
controlling the clock of the nodes and essentially being able to move time
forward and thus, for example, triggering a timeout without having to wait.

## Big picture

Let's start by recalling how the simulator interacts with the system under test
(SUT):

```
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
```

The simulation testing process starts by the developer prodiving a workload,
which is comprised of a generator of incoming messages to the SUT and a
property to check. The simulator generates some initial incoming messages and
their arrival times using the generator from the workload and spawns so called
"node handles" (one per node in the SUT).

The node handles are the simulator's API to the SUT which allows it to perform
the test (feed the nodes incoming messages using `handle` and get outgoing
messages back) and control time (via `nextTimer` and `advancetoTime`) so that
we can fast-forward past sleeps and timeouts (which would slow down the test).

The picture from the node handle's perspective looks like this (we'll explain
the interaction with the node in more detail below):

```
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
```

We want the node that we test to be as close to the node that we deploy (in
production) as possible. However in real deployments we can't fast forward
time, so `nextTimer` and `advanceToTime` are only part of simulation testing. A
small shim component takes care of this during simulation. This shim isn't
part of the deployed node, but otherwise the code that gets tested and deployed
is identical, with one exception: the runtime component. During a real
deployment, the runtime will be reading and sending bytes from, for example, a
TCP socket. While during simulation the shim will be writing incoming messages
to the runtime, for it to `receive`, and reading outgoing messages from the
runtime, which it `send`s. Timeouts in `receive` are mocked/faked by use of
`advanceToTime` in order to speed up testing.


The event loop code, which uses the runtime, and the state machine that gets
fed the incoming messages is the same during simulation and real deployment.
The state machine is what our DSL gets interpreted into and the effects it
produces are turned into outgoing messages, for the runtime to send to
approapriate destination, and timers for the event loop to keep track off.

Hopefully by now we've managed to paint a high-level picture of what's going
on, next let's try to make things more concrete by looking at the code.

## Extending the DSL

``` {.haskell include=../moskstraumen/src/Moskstraumen/Experiment/Node8.hs snippet=Node}
```

``` {.haskell include=../moskstraumen/src/Moskstraumen/Experiment/Node8.hs snippet=NodeF}
```

``` {.haskell include=../moskstraumen/src/Moskstraumen/Experiment/Node8.hs snippet=NodeState}
```

``` {.haskell include=../moskstraumen/src/Moskstraumen/Experiment/Node8.hs snippet=initialNodeState}
```

## Example: broadcast

``` {.haskell include=../moskstraumen/src/Moskstraumen/Example/Broadcast.hs snippet=BroadcastInput}
```
``` {.haskell include=../moskstraumen/src/Moskstraumen/Example/Broadcast.hs snippet=BroadcastOutput}
```
``` {.haskell include=../moskstraumen/src/Moskstraumen/Example/Broadcast.hs snippet=BroadcastState}
```

``` {.haskell include=../moskstraumen/src/Moskstraumen/Example/Broadcast.hs snippet=initialState}
```

``` {.haskell include=../moskstraumen/src/Moskstraumen/Example/Broadcast.hs snippet=broadcast}
```

## Semantics

``` {.haskell include=../moskstraumen/src/Moskstraumen/Experiment/Node8.hs snippet=runNode}
```

``` {.haskell include=../moskstraumen/src/Moskstraumen/Experiment/Node8.hs snippet=Effect}
```

``` {.haskell include=../moskstraumen/src/Moskstraumen/Experiment/Node8.hs snippet=runBody}
```

## Event loop

``` {.haskell include=../moskstraumen/src/Moskstraumen/Experiment/Node8.hs snippet=EventLoopState}
```

``` {.haskell include=../moskstraumen/src/Moskstraumen/Experiment/Node8.hs snippet=eventLoop}
```

``` {.haskell include=../moskstraumen/src/Moskstraumen/Experiment/Node8.hs snippet=stepEventLoop}
```

``` {.haskell include=../moskstraumen/src/Moskstraumen/Experiment/Node8.hs snippet=handleIncoming}
```

``` {.haskell include=../moskstraumen/src/Moskstraumen/Experiment/Node8.hs snippet=handleEffects}
```

## Example: Maelstrom and simulation testing broadcast

## Discussion: the gap between simulation and reality

* Event loop code
* Codec?
* Code paths in stepEventLoop that are never taken in simulation?
* In the node DSL if we do t1 <- getTime, t2 <- getTime then t1 == t2 as time
  doesn't move during a step
  - Alternative: We could make getTime into an effect which would suspend and get a callback
    once runtime.getTime finishes

* XXX: use profiler to check?
* XXX: can we use a faketime version of timeout to have a smaller gap?

## Conclusion and what's next



[^1]: The other main feature that sets deterministic simulation testing apart
    from Jepsen is the fact that the tests are deterministic and failures can
    be reproduced from a seed.
