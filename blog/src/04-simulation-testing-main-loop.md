# The main test loop of simulation testing

In the last post we sketched a high-level plan of how to implement
language agnostic simulation testing.

In this post we'll start working on the implementation.

We'll be using Haskell as our implementation language, however fear
not...

## High-level picture of how the simulator works

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

From the above recipe we can get something very close to property-based
testing, by:

  1. Generate and execute a test using the above recipe;
  2. Repeat N times;
  3. If one of the tests fail, try shrinking it to provide a minimal
     counterexample.

Later on we'll also introduce faults into the mix, but for now this will do.

## Representing the fake "world"

``` {.haskell include=../moskstraumen/src/Moskstraumen/Simulate.hs snippet=World}
```

``` {.haskell include=../moskstraumen/src/Moskstraumen/NodeId.hs snippet=NodeId}
```

``` {.haskell include=../moskstraumen/src/Moskstraumen/NodeHandle.hs snippet=NodeHandle}
```

``` {.haskell include=../moskstraumen/src/Moskstraumen/Simulate.hs snippet=Trace}
```

``` {.haskell include=../moskstraumen/src/Moskstraumen/Message.hs snippet=Message}
```

## Making the fake "world" move

``` {.haskell include=../moskstraumen/src/Moskstraumen/Simulate.hs snippet=stepWorld}
```

``` {.haskell include=../moskstraumen/src/Moskstraumen/Simulate.hs snippet=runWorld}
```

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


