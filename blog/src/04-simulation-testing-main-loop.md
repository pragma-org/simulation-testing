---
author: Stevan A
date: 2025-02-27
---

# The main test loop of simulation testing

In the [last post](03-simulation-testing-echo-example.md) we sketched a
high-level plan of how to implement language agnostic simulation testing.

In this post we'll start working on the implementation. In particular we'll
have a look at the simulator is implemented and how it's used to in the main
test loop that gives us simulation testing.

We'll be using Haskell as our implementation language, however fear
not, I'm aware it's not everybody's favorite language and I try to avoid any
clever uses in order to be accessible to the larger programming community.
Should anything be unclear, feel free to get in touch and I'll do my best to
explain it in a different way.

## High-level overview of how the simulator works

Before we start introducing code, let's try to visualise the end result:

![Picture of simulator and
nodes](https://raw.githubusercontent.com/pragma-org/simulation-testing/refs/heads/main/blog/image/simulator.svg)

The simulator consists of four things:

  1. A heap (or priority queue) of messages sorted by arrival time (the
     triangle in the picture);
  2. A pseudo-random number generator (PRNG);
  3. A variable number of "node handles" which connect the simulator to the SUT
     (nodes);
  4. A trace of client request and response messages to and from the system.

Given this a test run proceeds as follows:

  1. The developer provides a way to generate client requests and a way to
     check traces;
  2. The simulator generates a an initial heap of client requests using the
     developer supplied generator;
  3. The simulator pops the top of the heap, i.e. the message with the earliest
     arrival time, and delivers the message to the appropriate node and gets
     and responses back via its "node handle";
  4. If the response is a client response, then append it to the trace,
     otherwise it's a message to another node. For messages to other nodes we
     generate a random arrival time using the PRNG and put it back into heap
     (this process creates different message interleavings or different seeds
     to the PRNG);
  5. Keep doing step 3 and 4 until we run out of messages on the heap.
  6. Use the developer supplied trace checker to see if the test passed or not.

So, for example, for the echo example in the previous post the developer would
supply way of generating client requests that express the notion of "node $N$,
please echo message $M$ back to me" as well as a way to check if traces are
correct. A correct trace in the echo example amounts to "for each requests to a
node to echo something back, there's a response from that node which indeed
echos back the same message $M$".

From the above recipe we can get something very close to property-based
testing, using the following steps:

  1. Generate and execute a test using the above recipe;
  2. Repeat $N$ times;
  3. If one of the tests fail, try shrinking it to provide a minimal
     counterexample.

Later on we'll also introduce faults into the mix, but for now this will do.

## Representing the fake "world"

The simulator is manipulating a fake representation of the "world":

``` {.haskell include=../moskstraumen/src/Moskstraumen/Simulate.hs snippet=World}
```

This fake world consists of four parts, that we discussed above, the nodes and
their node handles, the heap of message ordered by arrival time, a
pseudo-random number generator and a trace of client request and response
messages.

The node id is just a string, just like in Maelstrom:

``` {.haskell include=../moskstraumen/src/Moskstraumen/NodeId.hs snippet=NodeId}
```

The node handle is an interface with two operations:

``` {.haskell include=../moskstraumen/src/Moskstraumen/NodeHandle.hs snippet=NodeHandle}
```

The `handle` operation is called with an arrival time and a message and returns
a sequence of responses, while `close` is used to shutdown the node handle (if
needed).

A trace is merely a list of messages:

``` {.haskell include=../moskstraumen/src/Moskstraumen/Simulate.hs snippet=Trace}
```

Where messages are defined as per the Maelstrom
[protocol](https://github.com/jepsen-io/maelstrom/blob/main/doc/protocol.md):

``` {.haskell include=../moskstraumen/src/Moskstraumen/Message.hs snippet=Message}
```

We'll leave out the exact definition of `Payload` as nothing in this post
depends on it (and there are multiple ways one can define it).

## Making the fake "world" move

The simulator steps through the heap of messages and delivers them to the
nodes via the node handle. The responses it gets from the handle are
partitioned into client responses and messages to other nodes. Client responses
get appended to the trace, together with the message that got delivered,
while the messages to other nodes get assigned random arrival times and fed
back into the heap of messages to be delivered.


``` {.haskell include=../moskstraumen/src/Moskstraumen/Simulate.hs snippet=stepWorld}
```

Note that in the case of the echo example there are no messages between nodes,
a node echos back the client request immediately without any communication with
other nodes. We'll see examples of communication between nodes before a client
response is made a bit later[^1].

Another aspect we've not seen yet, which will be important later, is timeouts. The
`handle` function is given the current simulated time by the simulator, which
allows the system under test to update its notion of time, potentially
triggering timeouts (without having to wait for them to happen in real time).

The above step function, takes one step in the simulation, we can run the
simulation to it's completion by merely keep stepping it until we run out of
messages to deliver:

``` {.haskell include=../moskstraumen/src/Moskstraumen/Simulate.hs snippet=runWorld}
```

We could imagine having other stopping criteria, e.g. stop after one minute of
real time, or after one year of simulated time, etc. Time-based stopping
criteria are more interesting if we have infinite generators of client requests
(which we currently don't).

## Connecting the fake world to the real world

We know how to simulate the network between $N$ nodes, but how messages get
`handle`d is abstracted away in the node handle interface. We don't have enough
all the pieces to be able to show a concrete implementation of `handle` yet.
However, we can make thing slightly more concrete by providing a way of
specifying how many nodes are in a test and how to spawn node handles:

``` {.haskell include=../moskstraumen/src/Moskstraumen/Simulate.hs snippet=Deployment}
```

Given the node count, a spawn function, a list of initial messages, and a PRNG,
we can construct a fake "world" as follows:

``` {.haskell include=../moskstraumen/src/Moskstraumen/Simulate.hs snippet=newWorld}
```

This fake world is now ready to be run by the simulator, as we described above.

## Running tests

At this point we got everything we need to use the simulator as the center
piece of our tests. We'll parametrised our tests by a configuration to be able
to control the tests:

``` {.haskell include=../moskstraumen/src/Moskstraumen/Simulate.hs snippet=TestConfig}
```
``` {.haskell include=../moskstraumen/src/Moskstraumen/Simulate.hs snippet=defaultTestConfig}
```

The number of tests parameter controls how many test cases we generate and
execute, in the sense of property-based testing. The number of nodes, we
covered above. Finally there's the replay seed, which is used to create the
PRNG. By using the same seed we can replay a test execution and get the same
result, which is useful if we want to share a failing test case with someone or
check if a patch fixes a bug.

Another parameter of the tests is a so called "workload", which captures the
notion of how client requests are generated and how traces are checked[^2]: 

``` {.haskell include=../moskstraumen/src/Moskstraumen/Workload.hs snippet=Workload}
```

Given the above we can write the main test loop:

``` {.haskell include=../moskstraumen/src/Moskstraumen/Simulate.hs snippet=blackboxTest}
```

The `pipeSpawn` function takes a file path to a binary and creates a node
handle via `stdin` and `stdout`, similar to Maelstrom. We'll see the concrete
implementation of this in a later post.

The only thing that remains is to loop `numberOfTests` times, generating and
executing the tests each time.

``` {.haskell include=../moskstraumen/src/Moskstraumen/Simulate.hs snippet=TestResult}
```
``` {.haskell include=../moskstraumen/src/Moskstraumen/Simulate.hs snippet=runTests}
```

Where running a single test creates a new fake world, simulates it and checks
the trace:

``` {.haskell include=../moskstraumen/src/Moskstraumen/Simulate.hs snippet=runTest}
```

## Conclusion and what's next

We've seen how one could go about implementing testing around
a simulation of a network between nodes in a distributed system.

There were a couple of things we had to leave out from the code:

  1. How generation of client requests is implemented;
  2. How to check that traces, that the simulator returns, are correct;
  3. How to shrink and present minimal counterexamples when the check fails;
  4. How to spawn node handles which allow us to communicate with nodes via
     `stdin` and `stdout` similar to Maelstrom.

This is what we'll turn our attention to next. Probably tackling point 1-3 in
one or two posts. For point 4 we need a bit more context, in particular we need
to introduce the deterministic event loop on top of which nodes are running
(the node handle will be connected to the event loop).


[^1]: For now I hope you can imagine something like: don't reply to the client
    until we've replicated the data among enough nodes so that we can ensure
    it's reliably there in case some nodes crash.

[^2]: The details of how `Gen` and `Form` are defined will be a subject of
    later posts.
