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


## The gap between simulation and reality

* Event loop code
* Codec?
* Code paths in stepEventLoop that are never taken in simulation?
* In the node DSL if we do t1 <- getTime, t2 <- getTime then t1 == t2 as time
  doesn't move during a step
  - Alternative: We could make getTime into an effect which would suspend and get a callback
    once runtime.getTime finishes

[^1]: The other main feature that sets deterministic simulation testing apart
    from Jepsen is the fact that the tests are deterministic and failures can
    be reproduced from a seed.
