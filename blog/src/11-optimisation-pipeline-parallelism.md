---
author: Stevan A
date: 2025-09-05
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

## Big picture

* Same semantics: so test sequential deployment, deploy parallel

## How it works

``` {.haskell include=../moskstraumen/src/Moskstraumen/Experiment/SourceSinkNode3.hs snippet=Node}
```

``` {.haskell include=../moskstraumen/src/Moskstraumen/Experiment/SourceSinkNode3.hs snippet=compose}
```
