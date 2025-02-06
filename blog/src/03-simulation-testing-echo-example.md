---
author: Stevan A
date: 2025-01-20
---

# Simulation testing the echo example

[Previously](https://github.com/pragma-org/simulation-testing/blob/main/blog/src/02-maelstrom-testing-echo-example.md)
we saw how we can black-box test the echo example using Jepsen via
Maelstrom, now let's have a look how we can simulation test the exact same
example without modifying it.

## Using same stdin/stout as Maelstrom

We start of by defining an interface between the simulator and the system under
test (SUT).

```haskell
data Interface m = Interface
  { handle :: Message -> m [Message]
  , close :: m ()
  }
```

One way we can make the simulator communicate with our SUT is via pipes, i.e.
the simulator writes incoming messages to the SUTs `stdin` and reads responses
via `stdout`:

```haskell
pipeInterface :: Handle -> Handle -> ProcessHandle -> Interface IO
pipeInterface hin hout processHandle =
  Interface
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

pipeSpawn :: FilePath -> IO (Interface IO)
pipeSpawn fp = do
  (Just hin, Just hout, _, processHandle) <-
    createProcess
      (proc fp []) {std_in = CreatePipe, std_out = CreatePipe}
  return (pipeInterface hin hout processHandle)
```

```haskell
data World m = World
  { nodes :: Map NodeId (Interface m)
  , messages :: [Message] -- XXX: should be a heap
  , prng :: StdGen
  , trace :: Trace
  }

type Trace = [Message]
```


```haskell
stepWorld :: (Monad m) => World m -> m (Either (World m) ())
stepWorld world = case world.messages of
  [] -> return (Right ())
  (msg : msgs) -> case Map.lookup msg.dest world.nodes of
    Nothing -> error ("stepWorld: unknown destination node: " ++ show msg.dest)
    Just node -> do
      -- XXX: will be used later when we assign arrival times for replies
      let (prng', prng'') = split world.prng
      msgs' <- node.handle msg
      let (clientReplies, nodeMessages) =
            partition (\msg0 -> "c" `Text.isPrefixOf` unNodeId msg0.dest) msgs'
      return
        $ Left
          World
            { nodes = world.nodes
            , messages = msgs ++ nodeMessages
            , prng = prng''
            , trace = world.trace ++ msg : clientReplies
            }

runWorld :: (Monad m) => World m -> m Trace
```

```haskell
newWorld ::
  (Monad m) => Deployment m -> [Message] -> StdGen -> m (World m)
newWorld deployment initialMessages prng = do
  let nodeNames =
        map
          (NodeId . ("n" <>) . Text.pack . show)
          [1 .. deployment.nodeCount]
  interfaces <-
    replicateM deployment.nodeCount (deployment.spawn)
  return
    World
      { nodes = Map.fromList (zip nodeNames interfaces)
      , messages = initialMessages
      , prng = prng
      , trace = []
      }
```

```haskell
data Deployment m = Deployment
  { nodeCount :: Int
  , spawn :: m (Interface m)
  }

echoPipeDeployment :: Deployment IO
echoPipeDeployment =
  Deployment
    { nodeCount = 1
    , spawn =
        pipeSpawn "/path/to/echo-binary"
    }
```


```haskell
test :: (Monad m) => Deployment m -> [Message] -> StdGen -> m Bool
test deployment initialMessages prng = do
  world <-
    newWorld
      deployment
      initialMessages
      prng
  resultingTrace <- runWorld world
  traverse_ (.close) world.nodes
  -- XXX: assert something about trace, e.g.:
  -- always (\req -> msg.kind == "echo" ==> 
  --   eventually (\resp -> resp.kind == "echo_ok" && resp.body == req.body))
  return True
```

```haskell
data Result = Success | Failure
  deriving (Show)

t' :: (Monad m) => Deployment m -> [Message] -> Seed -> Int -> m Result
t' deployment initialMessages seed = go (mkStdGen seed)
  where
    go _prng 0 = return Success
    go prng n = do
      let (prng', prng'') = split prng
      passed <- test deployment initialMessages prng'
      if passed
        then go prng'' (n - 1)
        else return Failure

t :: IO ()
t = do
  seed <- randomIO

  -- XXX: generate random messages (either upfront or during the test)
  let initialMessages =
        [ Message
            { src = "c1"
            , dest = "n1"
            , body =
                Payload
                  { kind = "echo"
                  , msgId = Just 0
                  , inReplyTo = Nothing
                  , fields = Map.fromList [("echo", String "hi")]
                  }
            }
        ]
  result <- t' echoPipeDeployment initialMessages seed numberOfTests
  print result
  where
    numberOfTests = 100
```

## Running the simulator

```
> :set +s
> t
Got: hi
Got: hi
Got: hi
[...]
Success
(0.21 secs, 9,013,848 bytes)
```

~60x faster than Jepsen

## Avoiding the overhead of the event loop

We can avoid creating an event loop and hook up the interface directly to the
SUT state machine, effectively creating a fake:

```haskell
pureSpawn ::
  (input -> Node state input output)
  -> state
  -> ValidateMarshal input output
  -> IO (Interface IO)
```

```haskell
echoPureDeployment :: Deployment IO
echoPureDeployment =
  Deployment
    { nodeCount = 1
    , spawn = pureSpawn echo () echoValidateMarshal
    }
```

```haskell
s :: Seed -> IO ()
s seed = do
  let initialMessages =
        [ Message
            { src = "c1"
            , dest = "n1"
            , body =
                Payload
                  { kind = "echo"
                  , msgId = Just 0
                  , inReplyTo = Nothing
                  , fields = Map.fromList [("echo", String "hi")]
                  }
            }
        ]
  result <- t' echoPureDeployment initialMessages seed numberOfTests
  print result
  where
    numberOfTests = 100
```

## Running the fake based simulation

```
> s 42
Got: hi
Got: hi
Got: hi
[...]
Success
(0.01 secs, 3,515,256 bytes)
```

~20x faster than above, or 1300x faster than Jepsen.

A lot of Jepsen's slowness is due to the JVM booting up, and `--time-limit` and
`--rate` can probably be tweaked to produce more requests faster.
