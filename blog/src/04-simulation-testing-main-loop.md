# The main test loop of simulation testing

In the last post we sketched a high-level plan of how to implement
language agnostic simulation testing.

In this post we'll start working on the implementation.



We'll be using Haskell as our implementation language, however fear
not...

## High-level overview

![Picture of simulator and nodes](image/simulator.svg)


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


