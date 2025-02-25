# The main test loop of simulation testing

In the last post we sketched a high-level plan of how to implement
language agnostic simulation testing.

In this post we'll start working on the implementation.

We'll be using Haskell as our implementation language, however fear
not...

## High-level overview

## Representing the fake "world"

``` haskell
data World m = World
  { nodes :: Map NodeId (NodeHandle m)
  , messages :: Heap Time Message
  , prng :: Prng
  , trace :: Trace
  }

```

``` haskell
newtype NodeId = NodeId Text
```

``` haskell
data NodeHandle m = NodeHandle
  { handle :: Time -> Message -> m [Message]
  , close :: m ()
  }

```

``` haskell
type Trace = [Message]

```

``` haskell
data Message = Message
  { src :: NodeId
  , dest :: NodeId
  , body :: Payload
  }
```

## Making the fake "world" move

``` haskell
stepWorld :: (Monad m) => World m -> m (Either (World m) ())
stepWorld world = case Heap.pop world.messages of
  Nothing -> return (Right ())
  Just ((arrivalTime, message), messages') ->
    case Map.lookup message.dest world.nodes of
      Nothing -> error ("stepWorld: unknown destination node: " ++ show message.dest)
      Just node -> do
        let (prng', prng'') = splitPrng world.prng
        msgs' <- node.handle arrivalTime message
        let (clientResponses, nodeMessages) =
              partition (isClientNodeId . dest) msgs'
            meanMicros = 20000 -- 20ms
            nodeMessages' = generateRandomArrivalTimes arrivalTime meanMicros nodeMessages prng'
        return
          $ Left
            World
              { nodes = world.nodes
              , messages = messages' <> nodeMessages'
              , prng = prng''
              , trace = world.trace ++ message : clientResponses
              }
```

``` haskell
runWorld :: (Monad m) => World m -> m Trace
runWorld world =
  stepWorld world >>= \case
    Right () -> return world.trace
    Left world' -> runWorld world'
```

## Connecting the fake world to the real world

``` haskell
data Deployment m = Deployment
  { numberOfNodes :: Int
  , spawn :: m (NodeHandle m)
  }

```

``` haskell
newWorld ::
  (Monad m) => Deployment m -> [Message] -> Prng -> m (World m)
newWorld deployment initialMessages prng = do
  let nodeIds =
        map
          (NodeId . ("n" <>) . Text.pack . show)
          [1 .. deployment.numberOfNodes]
  nodeHandles <-
    replicateM deployment.numberOfNodes deployment.spawn
  let (prng', prng'') = splitPrng prng
      meanMicros = 20000 -- 20ms
      initialMessages' = generateRandomArrivalTimes epoch meanMicros initialMessages prng'
  return
    World
      { nodes = Map.fromList (zip nodeIds nodeHandles)
      , messages = initialMessages'
      , prng = prng''
      , trace = []
      }

```

## Running tests

``` haskell
data TestConfig = TestConfig
  { numberOfTests :: Int
  , numberOfNodes :: Int
  , replaySeed :: Maybe Int
  }

```

``` haskell
defaultTestConfig :: TestConfig
defaultTestConfig =
  TestConfig
    { numberOfTests = 100
    , numberOfNodes = 5
    , replaySeed = Nothing
    }

```

``` haskell
data Workload = Workload
  { name :: Text
  , generateMessage :: Gen Message
  , property :: Form Message
  }

```

``` haskell
blackboxTestWith :: TestConfig -> FilePath -> Workload -> IO Bool
blackboxTestWith testConfig binaryFilePath workload = do
  (prng, seed) <- newPrng testConfig.replaySeed
  let deployment =
        Deployment
          { numberOfNodes = testConfig.numberOfNodes
          , spawn = pipeSpawn binaryFilePath seed
          }
  let (prng', _prng'') = splitPrng prng
  result <- runTests deployment workload testConfig.numberOfTests prng'
  case result of
    Failure trace -> do
      putStrLn ("Seed: " <> show seed)
      print trace
      return False
    Success -> return True

blackboxTest :: FilePath -> Workload -> IO Bool
blackboxTest = blackboxTestWith defaultTestConfig

```

``` haskell
data TestResult = Success | Failure Trace
  deriving stock (Eq, Show)

testResultToMaybe :: TestResult -> Maybe Trace
testResultToMaybe Success = Nothing
testResultToMaybe (Failure trace) = Just trace

```

``` haskell
runTests ::
  forall m.
  (Monad m) =>
  Deployment m
  -> Workload
  -> NumberOfTests
  -> Prng
  -> m TestResult
runTests deployment workload numberOfTests0 initialPrng =
  loop numberOfTests0 initialPrng
  where
    loop :: NumberOfTests -> Prng -> m TestResult
    loop 0 _prng = return Success
    loop n prng = do
      let size = 100 -- XXX: vary over time
      let initMessages =
            [ makeInitMessage (makeNodeId i) (map makeNodeId js)
            | i <- [1 .. deployment.numberOfNodes]
            , let js = [j | j <- [1 .. deployment.numberOfNodes], j /= i]
            ]
      let (prng', initialMessages) =
            Gen.runGen (Gen.listOf workload.generateMessage) prng size
      let initialMessages' :: [Message]
          initialMessages' =
            zipWith
              ( \message index -> message {body = message.body {msgId = Just index}}
              )
              initialMessages
              [0 ..]
      let (prng'', prng''') = splitPrng prng'
      result <-
        runTest deployment workload prng'' (initMessages <> initialMessages')
      case result of
        Success -> loop (n - 1) prng'''
        Failure _unShrunkTrace -> do
          initialMessagesAndTrace <-
            shrink
              (fmap testResultToMaybe . runTest deployment workload prng)
              (shrinkList (const []))
              initialMessages'
          let (_shrunkMessages, shrunkTrace) = NonEmpty.last initialMessagesAndTrace
          return (Failure shrunkTrace)

```

``` haskell
runTest ::
  (Monad m) =>
  Deployment m
  -> Workload
  -> Prng
  -> [Message]
  -> m TestResult
runTest deployment workload prng initialMessages = do
  world <-
    newWorld
      deployment
      initialMessages
      prng
  resultingTrace <- runWorld world
  traverse_ (.close) world.nodes
  if sat workload.property resultingTrace emptyEnv
    then return Success
    else return (Failure resultingTrace)

```

## Conclusion and what's next

- Console NodeHandle

- Main function?

- How do we generate client requests and check that the responses are
  correct?
