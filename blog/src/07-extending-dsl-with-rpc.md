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
on, next let's try to make things more concrete by looking at the code. We'll
look at each of the boxes in the above diagrams separately.

## Extending the DSL

First, let's have a look at what the DSL looks like. The new constructs are:

* `After`: which sets a timer and runs a provided action when it expires;
* `Rpc`: for making an RPC call, takes two continuations, so that it can handle
  both the failure and success case;
* `GetTime`: which returns the current node time;
* `Log`: which is used for logging.

``` {.haskell include=../moskstraumen/src/Moskstraumen/Experiment/Node8.hs snippet=Node}
```

``` {.haskell include=../moskstraumen/src/Moskstraumen/Experiment/Node8.hs snippet=NodeF}
```

The `Get` and `Put` constructs have been generalised slightly, since last time,
to operate over a so called "node state".

``` {.haskell include=../moskstraumen/src/Moskstraumen/Experiment/Node8.hs snippet=NodeState}
```

Which contains the "local state" of the node, the node id of itself, the
current time at the node, the neighbour node ids, the node id of the sender and
the in reply to message id of the message we are currently processing.

``` {.haskell include=../moskstraumen/src/Moskstraumen/Experiment/Node8.hs snippet=initialNodeState}
```

## Example: broadcast

To illustrate what this extended DSL is capable of, let's have a look at an
example from Jepsen's [Maelstrom](https://github.com/jepsen-io/maelstrom): a
gossip based broadcast system.

The broadcast nodes support four messages, initialisation (which supplies the
node with its unique node id and the node ids of its neighbours), topology
(which tells the node which neighbours are currencly reachable), broadcast
(which tells the node to broadcast some integer to its reachable neighbours)
and read (which returns all the integers that the node has seen):

``` {.haskell include=../moskstraumen/src/Moskstraumen/Example/Broadcast.hs snippet=BroadcastInput}
```

The responses to the above messages are all simple acknowledgements, except for
the read where we get back a list of integers as just mentioned:

``` {.haskell include=../moskstraumen/src/Moskstraumen/Example/Broadcast.hs snippet=BroadcastOutput}
```

In order to operate as intended the broadcast nodes need to keep track of
integers that they've seen and for each integer, which reachable neighbours it
still needs to broadcast them to:

``` {.haskell include=../moskstraumen/src/Moskstraumen/Example/Broadcast.hs snippet=BroadcastState}
```

Initially this state starts of being empty.

``` {.haskell include=../moskstraumen/src/Moskstraumen/Example/Broadcast.hs snippet=initialState}
```

We now got everything we need to define our broadcast nodes:

``` {.haskell include=../moskstraumen/src/Moskstraumen/Example/Broadcast.hs snippet=broadcast}
```

All the functions that are used in the broadcast example can be defined using
our DSL, here's for example the functions operating on the node state:

``` {.haskell include=../moskstraumen/src/Moskstraumen/Experiment/Node8.hs snippet=state}
```

Or the RPC construct:

``` {.haskell include=../moskstraumen/src/Moskstraumen/Experiment/Node8.hs snippet=rpc}
```

Or logging:

``` {.haskell include=../moskstraumen/src/Moskstraumen/Experiment/Node8.hs snippet=info}
```

Where a "generic operation"[^2] is defined as:

``` {.haskell include=../moskstraumen/src/Moskstraumen/Experiment/Node8.hs snippet=generic}
```

The type of `generic` is complicated, but all it does it wraps some `op`eration
in a node body.

The remaining functions used in the broadcast example follow the same pattern,
and are omitted to save space.

## Semantics

So now we got a language which is expressive enough to describe interesting
distributed systems, but so far it's merely a description. Next we'll have a
look at how we assign meaning to this language in terms of a simple state
machine.

The state machine takes a node state, an input and produces an updated node
state as well as a list of effects:

``` {.haskell include=../moskstraumen/src/Moskstraumen/Experiment/Node8.hs snippet=runNode}
```

Where the effects are the following:

``` {.haskell include=../moskstraumen/src/Moskstraumen/Experiment/Node8.hs snippet=Effect}
```

And running the body of a node is defined as following:

``` {.haskell include=../moskstraumen/src/Moskstraumen/Experiment/Node8.hs snippet=runBody}
```

## Event loop

We've now got a state machine which advances the node state given an input and
produces effects, next we'll define an event loop which drives our state machine.

For the event loop to be able to do its job, it needs a bit of state:

``` {.haskell include=../moskstraumen/src/Moskstraumen/Experiment/Node8.hs snippet=EventLoopState}
```

The next message id will be used to identify all outgoing messages (this is
needed in case we get a reply, so that we can correlated the reply with the
original message). The pending RPCs field holds the success-continuations of
RPCs that the node has sent (in a map keyed by the message id of the original
message). The pending timers field holds RPC timeouts as well as other timers
that the node has set for itself.

The event loop takes a node, it's initial local state, a codec (which decodes
and encodes incoming and outgoing messages) and a runtime (which receives
incoming messages and deals with the effects produced by the node).

``` {.haskell include=../moskstraumen/src/Moskstraumen/Experiment/Node8.hs snippet=eventLoop}
```

At each step of the event loop, we first check if there are any pending timers.
If there are no pending timers, we start waiting for an incoming message by
receiving via the runtime. A receive operation takes a timeout value in
microseconds as a parameter, and if no incoming message is receieved within
that time it will return `Nothing`, otherwise it returns the the incoming
message and its arrival time.

It gets more interesting when there's a pending timer. In that case we receieve
with a timeout which is the difference of what the time is now and when the
timer goes off, meaning that if we haven't receieved any incoming message by
the time that the timer goes off we'll get back `Nothing` and can proceed with
handling the timer.

``` {.haskell include=../moskstraumen/src/Moskstraumen/Experiment/Node8.hs snippet=stepEventLoop}
```

The above code just takes one step in the event loop, to actually run the event
loop we loop the step function as follows:

``` {.haskell include=../moskstraumen/src/Moskstraumen/Experiment/Node8.hs snippet=eventLoop}
```

The above code contains four pieces which we haven't seen yet: 

* `Codec`: for encoding and decoding messages;
* `handleIncoming`: for handling incoming messages;
* `handleEffects`: for handing the effects that our node produces when it
  processes an incoming message.
* `Runtime`: which is used for receiving and sending messages and logging.

Let's have a look at each of these in turn.

## Messages and their codec

``` {.haskell include=../moskstraumen/src/Moskstraumen/Experiment/Node8.hs snippet=Codec}
```

``` {.haskell include=../moskstraumen/src/Moskstraumen/Message3.hs snippet=Incoming}
```

``` {.haskell include=../moskstraumen/src/Moskstraumen/Message3.hs snippet=Outgoing}
```

``` {.haskell include=../moskstraumen/src/Moskstraumen/Message3.hs snippet=Message}
```
``` {.haskell include=../moskstraumen/src/Moskstraumen/Message3.hs snippet=Response}
```
``` {.haskell include=../moskstraumen/src/Moskstraumen/Message3.hs snippet=RpcError}
```

## Handling incoming messages and effects

``` {.haskell include=../moskstraumen/src/Moskstraumen/Experiment/Node8.hs snippet=handleIncoming}
```

``` {.haskell include=../moskstraumen/src/Moskstraumen/Experiment/Node8.hs snippet=handleEffects}
```

## Runtime

All the side-effects made by the event loop come from the so called runtime.


``` {.haskell include=../moskstraumen/src/Moskstraumen/Experiment/Node8.hs snippet=Runtime}
```

The reason for this interface is so that we can use different instances of it
during simulation testing and real deployment, without having to otherwise
change the event loop code.

For example where's a runtime that recieves messages on `stdin`, sends messages
on `stdout` and does logging on `stderr` (this is how Maelstrom talks to the
SUT it's testing).

``` {.haskell include=../moskstraumen/src/Moskstraumen/Experiment/Node8.hs snippet=consoleRuntime}
```

Another instance of the runtime interface is the simultion runtime, which is
used during simulation testing. This is the box called "shim" in the diagrams
from the overview.

``` {.haskell include=../moskstraumen/src/Moskstraumen/Experiment/Node8.hs snippet=shim}
```

Like the console runtime used by Maelstrom we use `stdin` and `stdout`, but
since simulation requires control over time we've extended the Maelstrom
"protocol" to also be able to get the next timer that a node is waiting for as
well as advance the time.

For a real deployment the runtime would use, for example, a TCP socket to do
the receiving and sending of messages and perhaps the signature would be
something like the following.

``` {.haskell include=../moskstraumen/src/Moskstraumen/Experiment/Node8.hs snippet=tcpRuntime}
```

## Node handle

The so called node handle, which is spawned by the simulator and allows it to
communicate with the SUT, needs to be extended to also be able to ask for the
next timer and advance the time.

``` {.haskell include=../moskstraumen/src/Moskstraumen/Experiment/Node8.hs snippet=NodeHandle}
```

``` {.haskell include=../moskstraumen/src/Moskstraumen/Experiment/Node8.hs snippet=HandleOutput}
```

``` {.haskell include=../moskstraumen/src/Moskstraumen/Experiment/Node8.hs snippet=simulationNodeHandle}
```

## Changes to the simulator




## Example: Maelstrom and simulation testing broadcast

The final thing left to do is to run our example. We can run it in two ways:

  1. Using the console runtime, which allows us to blackbox test it with
     Maelstrom;
  2. Using the simulation runtime, which allows us to simulation test it with
     the simulator.

Let's start with the console runtime:

``` {.haskell include=../moskstraumen/src/Moskstraumen/Example/Broadcast.hs snippet=libMain}
```

If we let this be the `main` and compile a binary out of it, we can then test
it with Maelstrom as follows:

```bash
./maelstrom test -w broadcast --bin "$BINARY_PATH" --time-limit 5 --log-stderr --rate 10

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

For simulation testing we instead stick the following into the `main` function
and compile a binary. This is almost the same as the above, with the exception
of the shim which allows the simulator to query the next timer and advance
time.

``` {.haskell include=../moskstraumen/src/Moskstraumen/Example/Broadcast.hs snippet=simulationLibMain}
```

We can then use this binary when calling our simulator from the REPL as
follows:

```
>>> let config = defaultTestConfig { numberOfTests = 10 }
>>> binary <- filter (/= '\n') <$> readProcess "cabal" ["list-bin", "broadcast-simulation"] ""
>>> outOfProcessSimulationTestWith config binary [] (broadcastWorkload config)

[...]

Metrics {droppedMessages = 424, partitions = 55, numberOfTests = 10}

Success!
```

Where out-of-process simulation testing is defined as follows:

``` {.haskell include=../moskstraumen/src/Moskstraumen/Simulate2.hs snippet=outOfProcessSimulationTestWith}
```

For completeness we should also mention that it's possible to write an
in-process simulator, which uses a node handle which doesn't spawn an external
process but rather calls `stepEventLoop` in the same thread as the simulator.
This only works if the SUT is written in the same language as the simulator
though, so what we showed above is more general albeit probably a bit slower
due to the serialisation overhead.

## Discussion: the gap between simulation and reality

* Event loop code
* Codec?
* Code paths in stepEventLoop that are never taken in simulation?
  - add asserts to confirm?
* In the node DSL if we do t1 <- getTime, t2 <- getTime then t1 == t2 as time
  doesn't move during a step
  - Alternative: We could make getTime into an effect which would suspend and get a callback
    once runtime.getTime finishes

* XXX: use profiler to check?
* XXX: can we use a faketime version of timeout to have a smaller gap?

## Conclusion and what's next

We've added constructs to our DSL for dealing with time, a key part of
distributed systems, and made the simulator able to fake the passage of time in
order to speed up testing involving timers.

The next step would be to add fault injection, e.g. network partitions or
latency, which would trigger timeout timers associated with RPC requests which
in turn would cause retries. This will ensure that our nodes are robust in the
presence of failures.

Another possible improvement is to extend the DSL to allow synchronous (or
blocking) RPC calls, which would make it easier to express some use cases (e.g.
the Datomic transactor
[example](https://github.com/jepsen-io/maelstrom/blob/main/doc/05-datomic/index.md)
from Maelstrom).


[^1]: The other main feature that sets deterministic simulation testing apart
    from Jepsen is the fact that the tests are deterministic and failures can
    be reproduced from a seed.

[^2]: Generic operation is Plotkin and Power's terminology from their work on
    algebraic effects.
