# A domain-specific language for simulation testing distributed systems

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
indeed determinisitic? This is the problem we'll tackle in this post,
and we'll do so by means of a domain-specific language inspired by
Jepsen's Maelstrom.

## Motivation

- If the programming languages we were using had deterministic runtimes
  then we could skip this, but this unfortunatelly not the case as we
  saw in a previous
  [post](https://github.com/pragma-org/simulation-testing/blob/main/blog/dist/03-simulation-testing-echo-example.md).

- Carve out a DSL which is expressive enough for distributed systems,
  while easy to make deterministic

- The DSL constructs are taken straight from Maelstrom

- "Runtime" is made deterministic, unlike most runtimes for Maelstrom

## Syntax

``` haskell
data NodeBody output = Reply output

type Node input output = input -> NodeBody output

echo :: Node String String
echo input = let output = input in Reply output
```

## Semantics

``` haskell
runNode :: Node input output -> input -> output
runNode node input = case node input of
  Reply output -> output
```

``` haskell
data ValidateMarshal input output = ValidateMarshal
  { validateInput :: Message -> Maybe input
  , marshalOutput :: output -> Message
  }
```

``` haskell
data Runtime = Runtime
  { receive :: IO [Message]
  , send :: Message -> IO ()
  }
```

``` haskell
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

- XXX: Codec

``` haskell
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

- XXX: NodeHandle

``` haskell
pipeNodeHandle :: Handle -> Handle -> ProcessHandle -> NodeHandle
pipeNodeHandle hin hout processHandle =
  NodeHandle
    { handle = \msg -> do
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

``` haskell
blackboxTestWith ::
  TestConfig -> FilePath -> (Seed -> [String]) -> Workload -> IO Bool
blackboxTestWith testConfig binaryFilePath args workload = do
  (prng, seed) <- newPrng testConfig.replaySeed
  let deployment =
        Deployment
          { numberOfNodes = testConfig.numberOfNodes
          , spawn = pipeSpawn binaryFilePath (args seed)
          }
  let (prng', _prng'') = splitPrng prng
  result <- runTests deployment workload testConfig.numberOfTests prng'
  handleResult result seed

blackboxTest :: FilePath -> Workload -> IO Bool
blackboxTest binary = blackboxTestWith defaultTestConfig binary (const [])

```

With this we've got all code needed to actually run the tests for our
echo example.

- XXX: Show real deployment of same code using TCP runtime?

## Conclusion and what's next

- Our runtime is trivially deterministic, over the next couple of posts
  we'll introduce more complicated examples which will require us to
  extend the syntax and event loop. For example we'll need some kind of
  asynchronous RPC construct and this won't be trivially deterministic
  anymore.
