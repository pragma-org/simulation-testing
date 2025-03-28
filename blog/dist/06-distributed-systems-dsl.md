# A domain-specific language for simulation testing distributed systems

*Work in progress, please don't share, but do feel free to get
involved!*

In past posts we've built a simulator and a workload generator and
checker for distributed systems. The assumption we made is that if the
distributed system we are building is deterministic, then we can test it
effectively. Where effectively means:

1.  It's fast, because we can simulate the passage of time and thus not
    have to wait for timeouts;
2.  It produces minimal counterexamples when the checker fails, because
    we can shrink the generated workload;
3.  Failures are reproducible, given the seed of the workload generator.

But how do we fulfill the assumption that our distributed system is
indeed determinisitic? This is the problem we'll start tackling in this
post, and we'll do so by means of introducing a domain-specific language
inspired by Jepsen's Maelstrom.

## Motivation

Hopefully by now it should already be clear why we need determinism, but
the need for a new domain-specific language deserves some explaination.

If the programming languages we were using had deterministic runtimes
then we could skip this, however this is unfortunately not the case as
we saw in a previous
[post](https://github.com/pragma-org/simulation-testing/blob/main/blog/dist/03-simulation-testing-echo-example.md).

In fact even seemingly pure things such as iterating over a hash map can
be non-determinisitic in some programming languages (because sometimes
insertion order matters).

Besides most programming languages are not very well suited for writing
distributed systems out of the box, so we typically need to add ways to
do:

1.  Message passing or RPC
2.  Timers for timeouts and periodic work
3.  Concurrency and parallelism
4.  Observability

Choices regarding how to do these thing idiomatically within each
programming language can be overwhelming, and even more so if the
distributed system uses several different programming languages.

In a way the domain-specific language that we will introduce abstracts
these necessary constructs, and provides a uniform way of writing
programs across languages while also achiving determinism and therefore
the ability to do simulation testing.

The constructs for our doman-specific language are taken straight from
Jepsen's Maelstrom, which already has been shown to be portable to many
different languages while at the same time being expressive enough to
implement a variety of distributed systems.

As pointed out eariler, they key difference between what we are about to
do and Maelstrom is that our workload generator and runtime will be
deterministic.

## Big picture

![Simulator interacting with
nodes](https://raw.githubusercontent.com/pragma-org/simulation-testing/refs/heads/main/blog/image/workload_and_simulator.svg)

![Node event
loop](https://raw.githubusercontent.com/pragma-org/simulation-testing/refs/heads/main/blog/image/node.svg)

## Syntax

We'll start of with a the bare minimum domain-specific language able to
express the echo example, and then we'll build upon this and then in
future posts we'll expand the set of examples that we can implement.

A node, in the distributed system, will be the basis for our language
and is merely a function from some input to a "node body":

``` haskell

type Node s i o a = i -> NodeBody s i o a

newtype NodeBody s i o a = NodeBody {unNodeBody :: Free (NodeF s i o) a}

```

``` haskell
data NodeF s i o x
  = Reply o (() -> x)
  | Get (s -> x)
  | Put s (() -> x)
  | Send NodeId i (() -> x)
```

For now the node body can only express the ability to reply to an input,
s. However this is already enough to express our echo example:

``` haskell
echo :: Node () String String ()
echo input = let output = input in NodeBody (Free (Reply output Pure))

```

## Semantics

``` haskell
data Message a = Message
  { src :: NodeId
  , dest :: NodeId
  , msgId :: Maybe MessageId
  , inReplyTo :: Maybe MessageId
  , payload :: a
  }
  deriving stock (Generic, Functor, Foldable, Traversable)
  deriving anyclass (FromJSON, ToJSON)

type MessageId = Word64

```

``` haskell
data Codec i o = Codec
  { decodeInput :: Value -> Either String i
  , encodeOutput :: o -> Value
  , encodeInput :: i -> Value
  }

```

``` haskell
data NodeState s i o = NodeState
  { localState :: s
  , nextMessageId :: MessageId
  , self :: NodeId
  }

```

``` haskell
initialNodeState :: s -> NodeState s i o
initialNodeState s =
  NodeState
    { localState = s
    , nextMessageId = 0
    , self = "uninitialised"
    }

```

``` haskell
runNode ::
  Node s i o a
  -> Codec i o
  -> NodeState s i o
  -> Message Value
  -> Either String (NodeState s i o, [Message Value], a)
runNode node codec s mv = case traverse codec.decodeInput mv of
  Right mi -> Right (runNodeBody (void mv) (node mi.payload) codec s)
  Left err -> Left err

```

``` haskell
runNodeBody ::
  Message ()
  -> NodeBody s i o a
  -> Codec i o
  -> NodeState s i o
  -> (NodeState s i o, [Message Value], a)
runNodeBody mv (NodeBody m) codec s = iterM go done m (s, [])
  where
    done x (s, messages) = (s, reverse messages, x)

    go (Reply o k) (s, acc) = do
      let messageId = s.nextMessageId
      let message =
            Message
              { src = mv.dest
              , dest = mv.src
              , msgId = Just messageId
              , inReplyTo = mv.msgId
              , payload = codec.encodeOutput o
              }
      k () (s {nextMessageId = messageId + 1}, message : acc)
    go (Send nodeId i k) (s, acc) = do
      let messageId = s.nextMessageId
      let message =
            Message
              { src = s.self
              , dest = nodeId
              , msgId = Just messageId
              , inReplyTo = Nothing
              , payload = codec.encodeInput i
              }
      k () (s {nextMessageId = messageId + 1}, message : acc)
    go (Get k) (s, acc) =
      k s.localState (s, acc)
    go (Put s' k) (s, acc) =
      k () (s {localState = s'}, acc)
```

## Event loop

- Test deployment vs production deployment

``` haskell
eventLoop :: Node_ s i o -> s -> Codec i o -> Runtime -> IO ()
eventLoop node initialState codec runtime =
  go (initialNodeState initialState)
  where
    go s = do
      incoming <- runtime.receive
      forM_ incoming $ \(_time, message) -> do
        case runNode node codec s message of
          Left err -> do
            putStrLn ("Failed to parse input: " <> err)
            go s
          Right (s', outgoing, ()) -> do
            runtime.send outgoing
            go s'

```

``` haskell
data Runtime = Runtime
  { send :: [Message Value] -> IO ()
  , receive :: IO [(Time, Message Value)]
  }

```

``` haskell
consoleRuntime :: IO Runtime
consoleRuntime = do
  hSetBuffering stdin LineBuffering
  hSetBuffering stdout LineBuffering
  hSetBuffering stderr LineBuffering
  return
    Runtime
      { receive = consoleReceive
      , send = consoleSend
      }
  where
    consoleReceive :: IO [(Time, Message Value)]
    consoleReceive = do
      line <- BS8.hGetLine stdin
      if BS8.null line
        then return []
        else do
          BS8.hPutStrLn stderr ("consoleRuntime: recieved: " <> line)
          case Json.eitherDecodeStrict line of
            Right message -> do
              now <- getCurrentTime
              return [(now, message)]
            Left err ->
              error
                $ "consoleRuntime: failed to decode message: "
                ++ show err
                ++ "\nline: "
                ++ show line

    consoleSend :: [Message Value] -> IO ()
    consoleSend messages =
      forM_ messages $ \message -> do
        BS8.hPutStrLn
          stderr
          ("consoleRuntime: sent: " <> LBS8.toStrict (Json.encode message))
        BS8.hPutStrLn stdout (LBS8.toStrict (Json.encode message))

```

``` haskell
testMain :: IO ()
testMain = eventLoop echo () echoCodec =<< consoleRuntime

```

``` haskell
tcpRuntime :: Port -> Map NodeId Port -> IO Runtime

prodMain :: Port -> Map NodeId Port -> IO ()
prodMain port peers = eventLoop echo () echoCodec =<< tcpRuntime port peers

```

## Interaction with simulator

``` haskell
data NodeHandle = NodeHandle
  { handle :: Time -> Message -> IO [Message]
  , close :: IO ()
  }

```

``` haskell
pipeNodeHandle :: FilePath -> [String] -> IO NodeHandle
pipeNodeHandle fp args = do
  (Just hin, Just hout, _, processHandle) <-
    createProcess
      (proc fp args) {std_in = CreatePipe, std_out = CreatePipe}
  return
    NodeHandle
      { handle = \_arrivalTime message -> do
          LBS8.hPutStr hin (Json.encode message)
          BS8.hPutStr hin "\n"
          hFlush hin
          line <- BS8.hGetLine hout
          case Json.eitherDecodeStrict line of
            Left err -> hPutStrLn stderr err >> return []
            Right msg' -> return [msg']
      , close = terminateProcess processHandle
      }

```

``` haskell
blackboxTestWith ::
  TestConfig -> FilePath -> (Seed -> [String]) -> Workload -> IO Bool
blackboxTestWith testConfig binaryFilePath args workload = do
  (prng, seed) <- newPrng testConfig.replaySeed
  let deployment =
        Deployment
          { numberOfNodes = testConfig.numberOfNodes
          , spawn = pipeNodeHandle binaryFilePath (args seed)
          }
  let (prng', _prng'') = splitPrng prng
  result <- runTests testConfig deployment workload prng'
  handleResult workload.prettyFailure result seed

blackboxTest :: FilePath -> Workload -> IO Bool
blackboxTest binary = blackboxTestWith defaultTestConfig binary (const [])

```

``` haskell
simulatorMain :: IO Bool
simulatorMain = blackboxTest "/path/to/test-main-binary" workload
  where
```

``` haskell
data Deployment = Deployment
  { numberOfNodes :: Int
  , spawn :: IO NodeHandle
  }

```

With this we've got all code needed to actually run the tests for our
echo example.

## Conclusion and what's next

- Our runtime is trivially deterministic, over the next couple of posts
  we'll introduce more complicated examples which will require us to
  extend the syntax and event loop. For example we'll need some kind of
  asynchronous RPC construct and this won't be trivially deterministic
  anymore.
