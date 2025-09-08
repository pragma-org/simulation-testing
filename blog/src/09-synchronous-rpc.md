---
author: Stevan A
date: 2025-09-08
status: sketch
---

# Extending the DSL with synchronous RPC

*Work in progress, please don't share, but do feel free to get involved!*

## Motivation

Currently our DSL support asynchronous RPC calls, that's we make a call,
install a success and a failure continuation to handle the outcomes of the call
and immediately continue doing more things within the node.

However sometimes it's useful to be able to block until the RPC call finishes,
that's what we'll cover below.

## Big picture

## How it works


First we extend our `data NodeF s i o x` with:

``` {.haskell include=../moskstraumen/src/Moskstraumen/Experiment/Node8.hs snippet=Vars}
```

``` {.haskell include=../moskstraumen/src/Moskstraumen/Experiment/Node8.hs snippet=syncRpc}
```

## Example: Datomic

Maelstom's Datomic
[example](https://github.com/jepsen-io/maelstrom/blob/main/doc/05-datomic/index.md).
