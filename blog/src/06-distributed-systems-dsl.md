---
author: Stevan A
date: 2025-03-18
status: sketch
---

# A domain-specific language for simulation testing distributed systems

*Work in progress, please don't share, but do feel free to get involved!*

In past posts we've built a simulator and a workload generator and checker for
distributed systems. The assumption we made is that if the distributed system
we are building is deterministic, then we can test it effectively. Where
effectively means:

  1. It's fast, because we can simulate the passage of time and thus not have
     to wait for timeouts; 
  2. It produces minimal counterexamples when the checker fails, because we can
     shrink the generated workload;
  3. Failures are reproducible, given the seed of the workload generator.

But how do we fulfill the assumption that our distributed system is indeed
determinisitic? This is the problem we'll start tackling in this post, and
we'll do so by means of introducing a domain-specific language inspired by
Jepsen's Maelstrom.

## Motivation

Hopefully by now it should already be clear why we need determinism, but the
need for a new domain-specific language deserves some explaination.

If the programming languages we were using had deterministic runtimes then we
could skip this, however this is unfortunately not the case as we saw in a
previous
[post](https://github.com/pragma-org/simulation-testing/blob/main/blog/dist/03-simulation-testing-echo-example.md).

In fact even seemingly pure things such as iterating over a hash map can be
non-determinisitic in some programming languages (because sometimes insertion
order matters).

Besides most programming languages are not very well suited for writing
distributed systems out of the box, so we typically need to add ways to do:

  1. Message passing or RPC
  2. Timers for timeouts and periodic work
  3. Concurrency and parallelism
  4. Observability

Choices regarding how to do these thing idiomatically within each programming
language can be overwhelming, and even more so if the distributed system uses
several different programming languages.

In a way the domain-specific language that we will introduce abstracts these
necessary constructs, and provides a uniform way of writing programs across
languages while also achiving determinism and therefore the ability to do
simulation testing.

The constructs for our doman-specific language are taken straight from Jepsen's
Maelstrom, which already has been shown to be portable to many different
languages while at the same time being expressive enough to implement a variety
of distributed systems.

As pointed out eariler, they key difference between what we are about to do and
Maelstrom is that our workload generator and runtime will be deterministic.

## Syntax

We'll start of with a the bare minimum domain-specific language able to express
the echo example, and then we'll build upon this and then in future posts we'll
expand the set of examples that we can implement.

A node, in the distributed system, will be the basis for our language and is
merely a function from some input to a "node body":

``` {.haskell include=../moskstraumen/src/Moskstraumen/Node5.hs snippet=Node}
```

``` {.haskell include=../moskstraumen/src/Moskstraumen/Node5.hs snippet=NodeF}
```

For now the node body can only express the ability to reply to an input, s.
However this is already enough to express our echo example:

``` {.haskell include=../moskstraumen/src/Moskstraumen/Node5.hs snippet=echo}
```


## Semantics


``` {.haskell include=../moskstraumen/src/Moskstraumen/Node5.hs snippet=Message}
```

``` {.haskell include=../moskstraumen/src/Moskstraumen/Node5.hs snippet=Codec}
```

``` {.haskell include=../moskstraumen/src/Moskstraumen/Node5.hs snippet=NodeState}
```

``` {.haskell include=../moskstraumen/src/Moskstraumen/Node5.hs snippet=initialNodeState}
```

``` {.haskell include=../moskstraumen/src/Moskstraumen/Node5.hs snippet=runNode}
```

``` {.haskell include=../moskstraumen/src/Moskstraumen/Node5.hs snippet=runNodeBody}
```

## Event loop

* Test deployment vs production deployment

``` {.haskell include=../moskstraumen/src/Moskstraumen/Node5.hs snippet=eventLoop}
```

``` {.haskell include=../moskstraumen/src/Moskstraumen/Node5.hs snippet=Runtime}
```

``` {.haskell include=../moskstraumen/src/Moskstraumen/Node5.hs snippet=consoleRuntime}
```


```haskell
tcpRuntime :: Port -> Map NodeId Port -> IO Runtime
```

## Interaction with simulator


``` {.haskell include=../moskstraumen/src/Moskstraumen/NodeHandle.hs snippet=NodeHandle}
```


``` {.haskell include=../moskstraumen/src/Moskstraumen/Node5.hs snippet=pipeNodeHandle}
```

``` {.haskell include=../moskstraumen/src/Moskstraumen/Simulate.hs snippet=blackboxTest}
```

With this we've got all code needed to actually run the tests for our echo
example.


## Conclusion and what's next

* Our runtime is trivially deterministic, over the next couple of posts we'll
  introduce more complicated examples which will require us to extend the
  syntax and event loop. For example we'll need some kind of asynchronous RPC
  construct and this won't be trivially deterministic anymore.
