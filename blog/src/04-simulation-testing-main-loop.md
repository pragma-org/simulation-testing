# The main test loop of simulation testing

In the last post we sketched a high-level plan of how to implement
language agnostic simulation testing.

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

![Picture of simulator and nodes](../image/simulator.svg)

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
supply way of generating client requests that express the notion of "node N,
please echo message M back to me" as well as a way to check if traces are
correct. A correct trace in the echo example amounts to "for each requests to a
node to echo something back, there's a response from that node which indeed
echos back the same message".

From the above recipe we can get something very close to property-based
testing, using the following steps:

  1. Generate and execute a test using the above recipe;
  2. Repeat N times;
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

The simulator steps throught the heap of messages and delievers them to the
nodes via the node handle. The responses it gets from the handle are
partitioned into client responses and messages to other nodes. Client responses
get appended to the trace, together wwith the message that got delievered,
while the messages to other nodes get assigned random arrival times and fed
back into the heap of messages to be delieved.


``` {.haskell include=../moskstraumen/src/Moskstraumen/Simulate.hs snippet=stepWorld}
```

Note that in the case of the echo example there are no messages between nodes,
a node echos back the client request immediately without any communication with
other nodes. We'll see examples of communication between nodes before a client
response is made a bit later[^1].

The above step function, takes one step in the simulation, we can run the
simulation to it's completion by merely keep stepping it until we run out of
messages to deliever:

``` {.haskell include=../moskstraumen/src/Moskstraumen/Simulate.hs snippet=runWorld}
```

We could imagine having other stopping criteria, e.g. stop after one minute of
real time, or after one year of simulated time, etc. Time-based stopping
critera are more interesting if we have infinite generators of client requests
(which we currently don't).

## Connecting the fake world to the real world

``` {.haskell include=../moskstraumen/src/Moskstraumen/Simulate.hs snippet=Deployment}
```

``` {.haskell include=../moskstraumen/src/Moskstraumen/Simulate.hs snippet=newWorld}
```

## Running tests

``` {.haskell include=../moskstraumen/src/Moskstraumen/Simulate.hs snippet=TestConfig}
```

``` {.haskell include=../moskstraumen/src/Moskstraumen/Simulate.hs snippet=defaultTestConfig}
```

``` {.haskell include=../moskstraumen/src/Moskstraumen/Workload.hs snippet=Workload}
```

``` {.haskell include=../moskstraumen/src/Moskstraumen/Simulate.hs snippet=blackboxTest}
```

``` {.haskell include=../moskstraumen/src/Moskstraumen/Simulate.hs snippet=TestResult}
```

``` {.haskell include=../moskstraumen/src/Moskstraumen/Simulate.hs snippet=runTests}
```

``` {.haskell include=../moskstraumen/src/Moskstraumen/Simulate.hs snippet=runTest}
```

## Conclusion and what's next

* Console NodeHandle

* Main function?

* How do we generate client requests and check that the responses are correct?


[^1]: For now I hope you can imagine something like: don't reply to the client
    until we've replicated the data among enough nodes so that we can ensure
    it's reliably there in case some nodes crash.

