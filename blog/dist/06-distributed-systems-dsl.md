# A domain-specific language for simulation testing distributed systems

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

consoleRuntime :: Codec -\> IO (Runtime IO) 31 │ consoleRuntime codec =
do 32 │ hSetBuffering stdin LineBuffering 33 │ hSetBuffering stdout
LineBuffering 34 │ hSetBuffering stderr LineBuffering 35 │ return 36 │
Runtime 37 │ { receive = consoleReceive 38 │ , send = consoleSend 39 │ ,
log = \text -\> Text.hPutStrLn stderr text 40 │ , -- NOTE: `timeout 0`
times out immediately while negative values 41 │ -- don't, hence the
`max 0`. 42 │ timeout = \micros -\> System.Timeout.timeout (max 0
micros) 43 │ , getCurrentTime = Time.getCurrentTime 44 │ , shutdown =
return () 45 │ } 46 │ where 47 │ consoleReceive :: IO \[(Time,
Message)\] 48 │ consoleReceive = do 49 │ -- XXX: Batch and read several
lines? 50 │ line \<- BS8.hGetLine stdin 51 │ if BS8.null line 52 │ then
return \[\] 53 │ else do 54 │ BS8.hPutStrLn stderr ("recieve: " \<\>
line) 55 │ case codec.decode line of 56 │ Right message -\> do 57 │ now
\<- Time.getCurrentTime 58 │ return \[(now, message)\] 59 │ Left err -\>
60 │ -- XXX: Log and keep stats instead of error. 61 │ error 62 │ \$
"consoleReceive: failed to decode message: " 63 │ ++ show err 64 │ ++
"\nline: " 65 │ ++ show line 66 │ 67 │ consoleSend :: Message -\> IO ()
68 │ consoleSend message = do 69 │ BS8.hPutStrLn stderr ("send: " \<\>
codec.encode message) 70 │ BS8.hPutStrLn stdout (codec.encode message)

│ pipeNodeHandle :: Handle -\> Handle -\> ProcessHandle -\> NodeHandle
127 │ pipeNodeHandle hin hout processHandle = 128 │ NodeHandle 129 │ {
handle = \_arrivalTime msg -\> do 130 │ BS8.hPutStr hin (encode
jsonCodec msg) 131 │ BS8.hPutStr hin "\n" 132 │ hFlush hin 133 │ line
\<- BS8.hGetLine hout 134 │ case decode jsonCodec line of 135 │ Left err
-\> hPutStrLn stderr err \>\> return \[\] 136 │ Right msg' -\> return
\[msg'\] 137 │ , close = terminateProcess processHandle 138 │ } 139 │
140 │ pipeSpawn :: FilePath -\> \[String\] -\> IO NodeHandle 141 │
pipeSpawn fp args = do 142 │ (Just hin, Just hout, \_, processHandle)
\<- 143 │ createProcess 144 │ (proc fp args) {std_in = CreatePipe,
std_out = CreatePipe} 145 │ return (pipeNodeHandle hin hout
processHandle)
───────┴────────────────────────────────────────────────────────

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

## Example: Broadcast

## Syntax extension: async RPC call

## Semantics of async RPC calls
