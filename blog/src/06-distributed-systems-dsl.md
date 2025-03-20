---
author: Stevan A
date: 2025-03-18
status: sketch
---

# A domain-specific language for simulation testing distributed systems

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

```haskell
data NodeBody output = Reply output

type Node input output = input -> NodeBody output

echo :: Node String String
echo input = let output = input in Reply output
```

## Semantics

```haskell
runNode :: Node input output -> (input -> output)
runNode node input = case node input of
  Reply output -> output
```


```haskell
data ValidateMarshal input output = ValidateMarshal
  { validateInput :: Message -> Maybe input
  , marshalOutput :: output -> Message
  }
```

```haskell
data Runtime = Runtime
  { receive :: IO [Message]
  , send :: Message -> IO ()
  }
```

```haskell
eventLoop :: Node input output -> ValidateMarshal input output -> Runtime -> IO ()
eventLoop node validateMarshal runtime = loop
  where
    loop = do
      messages <- runtime.receive
      let inputs = catMaybes (map validateMarshal.validateInput messages)
          outputs = map (runNode node) inputs
          messages' = map validateMarshal.marshalOutput outputs
      mapM_ runtime.send messages'
      loop
```

``` {.haskell include=../moskstraumen/src/Moskstraumen/Codec.hs snippet=Codec}
```

``` {.haskell include=../moskstraumen/src/Moskstraumen/Codec.hs snippet=jsonCodec}
```

```haskell
consoleRuntime :: Codec -> IO (Runtime IO)
consoleRuntime codec = do
  hSetBuffering stdin LineBuffering
  hSetBuffering stdout LineBuffering
  hSetBuffering stderr LineBuffering
  return
    Runtime
      { receive = consoleReceive
      , send = consoleSend
      }
  where
    consoleReceive :: IO [(Time, Message)]
    consoleReceive = do
      -- XXX: Batch and read several lines?
      line <- BS8.hGetLine stdin
      if BS8.null line
        then return []
        else do
          BS8.hPutStrLn stderr ("recieve: " <> line)
          case codec.decode line of
            Right message -> do
              return [message]
            Left err ->
              error
                $ "consoleReceive: failed to decode message: "
                ++ show err
                ++ "\nline: "
                ++ show line

    consoleSend :: Message -> IO ()
    consoleSend message = do
      BS8.hPutStrLn stderr ("send: " <> codec.encode message)
      BS8.hPutStrLn stdout (codec.encode message)
```

``` {.haskell include=../moskstraumen/src/Moskstraumen/NodeHandle.hs snippet=NodeHandle}
```

```haskell
pipeNodeHandle :: Handle -> Handle -> ProcessHandle -> NodeHandle
pipeNodeHandle hin hout processHandle =
  NodeHandle
    { handle = \_arrivalTime msg -> do
        BS8.hPutStr hin (encode jsonCodec msg)
        BS8.hPutStr hin "\n"
        hFlush hin
        line <- BS8.hGetLine hout
        case decode jsonCodec line of
          Left err -> hPutStrLn stderr err >> return []
          Right msg' -> return [msg']
    , close = terminateProcess processHandle
    }

pipeSpawn :: FilePath -> [String] -> IO NodeHandle
pipeSpawn fp args = do
  (Just hin, Just hout, _, processHandle) <-
    createProcess
      (proc fp args) {std_in = CreatePipe, std_out = CreatePipe}
  return (pipeNodeHandle hin hout processHandle)
```

``` {.haskell include=../moskstraumen/src/Moskstraumen/Simulate.hs snippet=blackboxTest}
```

With this we've got all code needed to actually run the tests for our echo
example.

* XXX: Show real deployment of same code using TCP runtime?

```haskell
tcpRuntime :: Port -> Map NodeId Port -> Codec -> IO (Runtime IO)
```

## Conclusion and what's next

* Our runtime is trivially deterministic, over the next couple of posts we'll
  introduce more complicated examples which will require us to extend the
  syntax and event loop. For example we'll need some kind of asynchronous RPC
  construct and this won't be trivially deterministic anymore.
