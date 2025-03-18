# Using "workloads" to test distributed systems

In the previous post, we started the implementation of our language
agnostic simulator.

We showed how given some initial client requests the simulator simulates
a possible concurrent execution of of said requests. But what should
those initial requests be and how do we know that the exeuction is
"correct"?

Both Jepsen and FoundationDB's simulation testing have the notion of a
"workload", which plays a critial role when testing distributed systems.
In this post we'll explain what workloads are in terms of constructs
that, hopefully, are more familar to most programmers.

## Motivation

In order to verfy that a system works as intended, we must first state
what the intension is. If we think of the system, which might consist of
many different smaller subsystems or components, as one big black box,
then the intension is typically stated from the point of view of a
client (or user) of the system.

The client is typically a human being trying to achieve something, and
from the client's point of view the situation looks something like this:

           +--------+    request    +--------+
           |        | ------------> |        |
           | Client |               | System |
           |        | <------------ |        |
           +--------+    response   +--------+

All the client can do is to feed the system some input and observe some
kind of output, and so the intension of the client is typically
specified in terms of what kind of response is expected to a request in
any of the possible states that the system can be in.

It's this intution we shall make precise.

## Definition of workload

So a workload is three things:

1.  What are the requests that the client is expected to do (including
    potentially how they evolve over time as it receives responses). In
    property-based testing terminology this is a generator of inputs;
2.  Some way of checking that the responses we get back from the system
    "make sense". In property-based testing terminology this would be an
    invariant or a model of the system under test;
3.  Since one of the main purposes of distributed systems is to be able
    to withstand failures of individual nodes in the system, the
    workload should also specify under which failures the system under
    test should be able to withstand.

## Example workloads

For example, let's say that the system is a file system.

- Reusability of workloads

## Generation

- "Online" vs "offline" generation

## Model / invariants

- LTL
- State machine?
- Eventual consistancy? (Enough to test broadcast example that will
  appear in next post?)

## Faults

### CFT

- Async networking

  - Partitions (uni- and bi-directional)
  - Message loss
  - Message duplication
  - Message reordering (latency)
  - Message corruption

- Crashes

- Clock skews

- Long I/O or garbage collection pauses

### BFT

- Disk failures ("semi-byzantine")
  <https://docs.tigerbeetle.com/concepts/safety/#storage-fault-tolerance>

- Malicious message mutations

## Connection to property-based testing

- Recall offline test loop, using event loop from previous post
- Adding faults to the mix

## Conclusion and future work

- How to generate realistic workloads? Operational profile / usage model
