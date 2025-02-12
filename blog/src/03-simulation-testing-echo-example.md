---
author: Stevan A
date: 2025-02-07
---

# Sketching how to simulation test distributed systems

In the last post we saw how to test a simple distributed system, a node that
echos back the requests it gets, using Jepsen via Maelstrom.

We concluded by listing the pros and cons with the Maelstrom approach: it's
language agnostic which is good, but the tests are non-determinstic (rerunning
might give different results) and there's no shrinking.

In this post we'll highlight the sources of the non-determinism in the
Maelstrom approach, and then sketch how we can make it deterministic and thus
closer to simulation testing proper.

## Maelstrom the language

I'm a programming language person, so I like to see every problem through the
lens of programming languages[^1].

When I look at Maelstrom what I see is a programming language (or
domain-specific language) for distributed systems. We've seen it already in our
simple echo example:

```
node (Echo text) = reply (Echo_ok text)
```

This language hides the fact from where (what IP address, socket, etc) the
messages are coming and where to send the reply back to. It doesn't specify how
the messages are encoded on the wire (codec), not does it talk about what the
wire is (what communication channel is used between nodes).

It's good that the language hides all these details, because it lets us focus
on the essence of the node we are writing, in this case an echo node.

For more complicated distributed systems this language will need to be
extended, as we shall see later in the series.

However already this simple language is enough to illustrate the
non-determinism in Maelstrom.

## Maelstrom's non-deterministic runtimes

The way Maelstrom achieves language agnosticism is by:

  1. Making the Maelstrom language easy to implement in any other language, and;
  2. By specifying a
     [protocol](https://github.com/jepsen-io/maelstrom/blob/main/doc/protocol.md)
     for what the format and codec for messages are.

One source of non-determinism is the implementations of the Maelstrom language.

Through the lens of programming languages, we can think of the Maelstrom
language as a purely syntactic construct, while the implementations of the
language as an interpreter or a runtime.

At the time of writing there are
[eight](https://github.com/jepsen-io/maelstrom/tree/main/demo) runtimes written
in different languages.

I've not looked at all of them in detail, but the Ruby one (which is used in
the official Maelstrom documentation) and the Go one (which is used in Fly.io's
popular [Gossip Glomers](https://fly.io/dist-sys/)) are both non-determinstic.

To see where the non-determinism comes we need to have a look at how this node
runtime is implemented. In the previous post we hinted at how the Ruby version
worked, so let's switch to Go and have a look at how our echo example can be
implemented:

```go
func main() {
    n := maelstrom.NewNode()

    // Register a handler for the "echo" message that responds with an "echo_ok".
    n.Handle("echo", func(msg maelstrom.Message) error {
        // Unmarshal the message body as an loosely-typed map.
        var body map[string]any
        if err := json.Unmarshal(msg.Body, &body); err != nil {
            return err
        }

        // Update the message type.
        body["type"] = "echo_ok"

        // Echo the original message back with the updated message type.
        return n.Reply(msg, body)
    })

    // Execute the node's message loop. This will run until STDIN is closed.
    if err := n.Run(); err != nil {
        log.Printf("ERROR: %s", err)
        os.Exit(1)
    }
}
```

As you can see, all interesting bits (`Handle`, `Reply`, and `Run`) all use
`Node` which comes from the `maelstrom` library, this is what I've been calling
the runtime. Also note that in this example, without digging into the
implemention of the runtime, there's no non-determinism.

So let's dig a layer deeper...


* Non-deterministic runtimes

```go
                // Handle message in a separate goroutine.
                n.wg.Add(1)
                go func() {
                        defer n.wg.Done()
                        rand.Seed(time.Now().UnixNano())
                        // 0 to 10 ms
                        randomSleepTime := time.Duration(rand.Intn(11)) * time.Millisecond
                        time.Sleep(randomSleepTime)
                        n.handleMessage(h, msg)
                }()
```

```bash
 ~/go/bin/maelstrom-echo < <(echo '{"body":{"type":"echo", "echo": "hi_1"}}' & echo '{"body":{"type":"echo", "echo": "hi_2"}}')
```

```
2025/02/07 12:20:03 Received {  {"type":"echo", "echo": "hi_2"}}
2025/02/07 12:20:03 Received {  {"type":"echo", "echo": "hi_1"}}
2025/02/07 12:20:03 Sent {"body":{"echo":"hi_1","in_reply_to":0,"type":"echo_ok"}}
{"body":{"echo":"hi_1","in_reply_to":0,"type":"echo_ok"}}
2025/02/07 12:20:03 Sent {"body":{"echo":"hi_2","in_reply_to":0,"type":"echo_ok"}}
{"body":{"echo":"hi_2","in_reply_to":0,"type":"echo_ok"}

2025/02/07 12:21:01 Received {  {"type":"echo", "echo": "hi_2"}}
2025/02/07 12:21:01 Received {  {"type":"echo", "echo": "hi_1"}}
2025/02/07 12:21:01 Sent {"body":{"echo":"hi_2","in_reply_to":0,"type":"echo_ok"}}
{"body":{"echo":"hi_2","in_reply_to":0,"type":"echo_ok"}}
2025/02/07 12:21:01 Sent {"body":{"echo":"hi_1","in_reply_to":0,"type":"echo_ok"}}
{"body":{"echo":"hi_1","in_reply_to":0,"type":"echo_ok"}}
```

* Kyle Kingsbury suggests single threaded coroutine-based runtime as an alternative

* imagine we got determinstic runtime

* still need to fix non-determinism in Jepsen, e.g. randomness in how messages
  are generated (we saw how echo uses rand-int), random delays, etc

* Rather than patching Jepsen, and introducing Clojure as a dependency, let's
  just reimplement the test case generation and checking machinary from
  scratch.

* This might seem like a lot of work, but recall that property-based testing
  essentially provides all we need, and I've written about how we can implement
  this from scratch in the
  [past](https://stevana.github.io/the_sad_state_of_property-based_testing_libraries.html).

* QuickCheck style generators and shrinkers

* Test loop
  - console
  - simulation
  - tcp?

* Next: ?

#### Old

[Previously](https://github.com/pragma-org/simulation-testing/blob/main/blog/src/02-maelstrom-testing-echo-example.md)
we saw how we can black-box test the echo example using Jepsen via Maelstrom,
now let's have a look how we can simulation test the exact same example without
modifying it.


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

[^1]: Could be a blessing but more likely it's a curse.
