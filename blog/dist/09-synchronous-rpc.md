# Extending the DSL with synchronous RPC

*Work in progress, please don't share, but do feel free to get
involved!*

## Motivation

Currently our DSL support asynchronous RPC calls, that's we make a call,
install a success and a failure continuation to handle the outcomes of
the call and immediately continue doing more things within the node.

However sometimes it's useful to be able to block until the RPC call
finishes, that's what we'll cover below.

## How it works

First we extend our `data NodeF s i o x` with variables:

``` haskell
    NewVar (VarId -> x)
  | forall v. DeliverVar VarId v x
  | forall v. AwaitVar VarId (v -> x)
```

``` haskell
syncRpc ::
  NodeId
  -> i
  -> (RpcError -> NodeBody s i o ())
  -> NodeBody s i o (Either RpcError o)
syncRpc nodeId i failure = do
  varId <- generic NewVar
  generic
    $ Rpc
      nodeId
      i
      failure
      (\o -> generic_ (DeliverVar varId o))
  generic (AwaitVar varId)

```

For the semantics of variables see the [older
version](https://github.com/pragma-org/simulation-testing/blob/main/moskstraumen/src/Moskstraumen/Node4.hs).

## Example: Datomic

Maelstom's Datomic
[example](https://github.com/jepsen-io/maelstrom/blob/main/doc/05-datomic/index.md)
and an
[implementation](https://github.com/pragma-org/simulation-testing/blob/main/moskstraumen/src/Moskstraumen/Example/KeyValueStore.hs)
of it in an older version of our DSL.
