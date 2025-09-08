# Optimisation: pipeline parallelism

*Work in progress, please don't share, but do feel free to get
involved!*

In this post we'll show how to add pipeline parallelism to our
domain-specific language (DSL) for writing distributed systems.

## Motivation

So far our DSL has no way to express parallelism. We can do thing
concurrently, by means of RPC calls, sleep and recursion, but on a
single node only a single CPU/core is used.

## Big picture

- Same semantics: so test sequential deployment, deploy parallel

## How it works

``` haskell
type Node s k o a = Free (NodeF s k o) a

data NodeF s k o x
  = forall i. Await (Maybe (k i)) (Either i (NodeId, Json.Value) -> x)
  | Yield (Either o (NodeId, Json.Value)) (() -> x)
  | Get (s -> x)
  | Put s (() -> x)
  | forall a. LiftIO (IO a) (a -> x)
  | Stop
  | RPC NodeId Json.Value (RPCError -> x) (Json.Value -> x) (() -> x)

```

``` haskell
(>>>) ::
  Node (NodeState s) (Is a) b ()
  -> Node (NodeState s) (Is b) c ()
  -> Node (NodeState s) (Is a) c ()
```
