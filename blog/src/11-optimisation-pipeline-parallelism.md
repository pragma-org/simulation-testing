---
author: Stevan A
date: 2025-09-09
status: sketch
---

# Optimisation: pipeline parallelism

*Work in progress, please don't share, but do feel free to get involved!*

In this post we'll show how to add pipeline parallelism to our domain-specific
language (DSL) for writing distributed systems.

## Motivation

So far our DSL has no way to express parallelism. We can do thing concurrently,
by means of RPC calls, sleep and recursion, but on a single node only a single
CPU/core is used.

In order to make better use of our hardware we'd like change the DSL so that we
can describe stages which can be run in parallel.

## Big picture

The idea is that instead of the DSL describing a monolithic node, we make to
describe a stage that can be composed with other stages to form the final node.

So if we think of the old monolithic node as some function `m`:

```
              +---------------------------+
              |                  Old node |
              |                           |
              |  +--------------------+   |
              |  |         m          |   |
              |  +--------------------+   |
              |                           |
              +---------------------------+
```

Then we'd like to break `m` up in a composition of `f >>> g >>> h`:

```
              +---------------------------+
              |                      Node |
              |                           |
              |   +---+   +---+   +---+   |
              |   | f +-->| g +-->| h |   |
              |   +---+   +---+   +---+   |
              |                           |                        |
              +---------------------------+
```

Such that `m ~ f >>> g >>> h` where `~` is observably equivalent, but each
stage `f`, `g`, `h` can be run on a separate CPU/core and thus give us
parallelism.

The fact that the monolithic, or sequential, version is observably equivalent
to the parallel one is key, because on one hand it shows that the parallelism
doesn't introduce non-determinism and on the other hand it allows us to
simulation test the sequential (or composed) variant and deploy the parallel
variant. Thus avoiding simulating parallel states, while getting parallelism in
production.

## Possibilities to explore

One possible source of inspiration is Edward Kmett's
[`machines`](https://hackage.haskell.org/package/machines) library:

``` {.haskell include=../moskstraumen/src/Moskstraumen/Experiment/SourceSinkNode3.hs snippet=Node}
```

Where nodes, or stages, can be composed as follows:

``` {.haskell include=../moskstraumen/src/Moskstraumen/Experiment/SourceSinkNode3.hs snippet=compose}
```

One way to potentially achieve what we want is to introduce a second DSL for
describing pipelines (connected stages):

```haskell
data Pipeline a b where
  Stage :: Node a b -> Pipeline a b
  Compose :: Node a b -> Node b c -> Pipeline a c
```

One could then take such a pipeline and either compose all stages into a single
one for testing, or fork a thread for each stage and connect them with queues
for parallelism in a production deployment.

The tricky part is how do we compose the DSL extended with state, RPC, sleep
etc. For example should each stage have its own state type? How are RPC
responses made by some stage propagated back to that stage, should they go
through all the prior stages? Should intermediate stages even be allowed to
sleep?
