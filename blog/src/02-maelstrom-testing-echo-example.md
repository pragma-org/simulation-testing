---
author: Stevan A
date: 2025-01-20
---

# Maelstrom testing echo example

In this post we'll have a look at a very simple distributed system where the
nodes simply echo back whatever message one sends them.

We'll separate the "business logic" from all the I/O involved in logging and
sending messages.

## Functional core of SUT

```haskell
data EchoInput = Init NodeId [NodeId] | Echo Text

data EchoOutput = InitOk | EchoOk Text

type EchoState = ()

echo :: EchoInput -> Node EchoState EchoInput EchoOutput
echo (Init myNodeId myNeighbours) = do
  info ("Initalising: " <> unNodeId myNodeId)
  setPeers myNeighbours
  reply InitOk
echo (Echo text) = do
  info ("Got: " <> text)
  reply (EchoOk text)
```

## Imperative shell of SUT

```haskell
libMain :: IO ()
libMain =
  consoleEventLoop
    echo
    ()
    echoValidateMarshal
```

```haskell
consoleEventLoop ::
  (input -> Node state input output)
  -> state
  -> ValidateMarshal input output
  -> IO ()
consoleEventLoop node initialState validateMarshal = do
  runtime <- consoleRuntime jsonCodec
  eventLoop node initialState validateMarshal runtime
```

```haskell
eventLoop :: 
  (Monad m) =>
  (input -> Node state input output)
  -> state
  -> ValidateMarshal input output
  -> Runtime m
  -> m ()
eventLoop node initialState validateMarshal runtime =
  loop (initialNodeState initialState)
  where
    loop nodeState = do
      event <- runtime.source
      let (nodeState', effects) = handleEvent event nodeState
      mapM_ runtime.sink effects
      loop nodeState'
```

```haskell
data Runtime m = Runtime
  { source :: m Event
  , sink :: Effect -> m ()
  }
```

```haskell
data Event = MessageEvent Message | [...]

data Effect
  = SEND Message
  | LOG Text
  | [...]
```

## Manual test

If we create an executable using `libMain` from above and run it, then we can
feed it input via `stdin` and get logging on `stderr` and responses on
`stdout`:

```
$ cabal run echo
{"src": "c1", "dest": "n1", "body": {"msg_id": 1, "type": "echo", "echo": "hello there"}}
Got: hello there
{"body":{"echo":"hello there","in_reply_to":1,"msg_id":1,"type":"echo_ok"},"dest":"c1","src":"uninitialised"}
```

## Maelstrom tests

Why would we want to do messaging over `stdin` and `stdout`? Well there's this
wrapper around Jepsen, called
[Maelstrom](https://github.com/jepsen-io/maelstrom) which takes a path to a
binary and spawns a process per node and then does the message orchestration
between the nodes via `stdin` and `stdout`:

```
$ ./maelstrom test -w echo --bin echo --time-limit 5 --log-stderr --rate 10 --nodes n1
2025-01-20 12:08:02,011{GMT}	INFO	[jepsen test runner] jepsen.core: Test version 016086a90274077d611eda10e9d56398762040ff (plus uncommitted changes)
2025-01-20 12:08:02,011{GMT}	INFO	[jepsen test runner] jepsen.core: Command line:
lein run test -w echo --bin /home/stevan/src/simulation-testing/moskstraumen/dist-newstyle/build/x86_64-linux/ghc-9.10.1/moskstraumen-0.0.0/x/echo/build/echo/echo --time-limit 5 --log-stderr --rate 10 --nodes n1
2025-01-20 12:08:02,053{GMT}	INFO	[jepsen test runner] jepsen.core: Running test:
{:args []
 :remote
 #jepsen.control.retry.Remote{:remote #jepsen.control.scp.Remote{:cmd-remote #jepsen.control.sshj.SSHJRemote{:concurrency-limit 6,
                                                                                                             :conn-spec nil,
                                                                                                             :client nil,
                                                                                                             :semaphore nil},
                                                                 :conn-spec nil},
                              :conn nil}
 :log-net-send false
 :node-count nil
 :availability nil
 :max-txn-length 4
 :concurrency 1
 :db
 #object[maelstrom.db$db$reify__16612
         "0x3cdf8aa5"
         "maelstrom.db$db$reify__16612@3cdf8aa5"]
 :max-writes-per-key 16
 :leave-db-running? false
 :name "echo"
 :logging-json? false
 :start-time
 #object[org.joda.time.DateTime "0x4a282c78" "2025-01-20T12:08:01.962+01:00"]
 :nemesis-interval 10
 :net
 #object[maelstrom.net$jepsen_net$reify__15721
         "0x2700609f"
         "maelstrom.net$jepsen_net$reify__15721@2700609f"]
 :client
 #object[maelstrom.workload.echo$client$reify__17402
         "0x141cee26"
         "maelstrom.workload.echo$client$reify__17402@141cee26"]
 :barrier
 #object[java.util.concurrent.CyclicBarrier
         "0xecd3a9b"
         "java.util.concurrent.CyclicBarrier@ecd3a9b"]
 :log-stderr true
 :pure-generators true
 :ssh {:dummy? true}
 :rate 10.0
 :checker
 #object[jepsen.checker$compose$reify__11089
         "0x58d9cd6"
         "jepsen.checker$compose$reify__11089@58d9cd6"]
 :argv
 ("test"
  "-w"
  "echo"
  "--bin"
  "/home/stevan/src/simulation-testing/moskstraumen/dist-newstyle/build/x86_64-linux/ghc-9.10.1/moskstraumen-0.0.0/x/echo/build/echo/echo"
  "--time-limit"
  "5"
  "--log-stderr"
  "--rate"
  "10"
  "--nodes"
  "n1")
 :nemesis
 (jepsen.nemesis.ReflCompose
  {:fm {:start-partition 0,
        :stop-partition 0,
        :kill 1,
        :start 1,
        :pause 1,
        :resume 1},
   :nemeses [#unprintable "jepsen.nemesis.combined$partition_nemesis$reify__16905@21ad0060"
             #unprintable "jepsen.nemesis.combined$db_nemesis$reify__16886@5233b7ad"]})
 :nodes ["n1"]
 :test-count 1
 :latency {:mean 0, :dist :constant}
 :bin
 "/home/stevan/src/simulation-testing/moskstraumen/dist-newstyle/build/x86_64-linux/ghc-9.10.1/moskstraumen-0.0.0/x/echo/build/echo/echo"
 :generator
 #object[jepsen.util.Forgettable
         "0x64001530"
         (jepsen.generator.TimeLimit
          {:limit 5000000000,
           :cutoff nil,
           :gen (jepsen.generator.Any
                 {:gens [(jepsen.generator.OnThreads
                          {:f #{:nemesis},
                           :context-filter #object[jepsen.generator.context$make_thread_filter$lazy_filter__12077
                                                   "0x1f299fc3"
                                                   "jepsen.generator.context$make_thread_filter$lazy_filter__12077@1f299fc3"],
                           :gen nil})
                         (jepsen.generator.OnThreads
                          {:f #jepsen.generator.context.AllBut{:element :nemesis},
                           :context-filter #object[jepsen.generator.context$make_thread_filter$lazy_filter__12077
                                                   "0xb997735"
                                                   "jepsen.generator.context$make_thread_filter$lazy_filter__12077@b997735"],
                           :gen (jepsen.generator.Stagger
                                 {:dt 200000000,
                                  :next-time nil,
                                  :gen (jepsen.generator.EachThread
                                        {:fresh-gen #object[maelstrom.workload.echo$workload$fn__17421
                                                            "0x178826db"
                                                            "maelstrom.workload.echo$workload$fn__17421@178826db"],
                                         :context-filters #object[clojure.core$promise$reify__8621
                                                                  "0x7f913c47"
                                                                  {:status :pending,
                                                                   :val nil}],
                                         :gens {}})})})]})})]
 :log-net-recv false
 :os
 #object[maelstrom.net$jepsen_os$reify__15724
         "0x2c9573f1"
         "maelstrom.net$jepsen_os$reify__15724@2c9573f1"]
 :time-limit 5
 :workload :echo
 :consistency-models [:strict-serializable]
 :topology :grid}

2025-01-20 12:08:03,802{GMT}	INFO	[jepsen node n1] maelstrom.net: Starting Maelstrom network
2025-01-20 12:08:03,803{GMT}	INFO	[jepsen test runner] jepsen.db: Tearing down DB
2025-01-20 12:08:03,804{GMT}	INFO	[jepsen test runner] jepsen.db: Setting up DB
2025-01-20 12:08:03,806{GMT}	INFO	[jepsen node n1] maelstrom.service: Starting services: (lin-kv lin-tso lww-kv seq-kv)
2025-01-20 12:08:03,807{GMT}	INFO	[jepsen node n1] maelstrom.db: Setting up n1
2025-01-20 12:08:03,808{GMT}	INFO	[jepsen node n1] maelstrom.process: launching /home/stevan/src/simulation-testing/moskstraumen/dist-newstyle/build/x86_64-linux/ghc-9.10.1/moskstraumen-0.0.0/x/echo/build/echo/echo []
2025-01-20 12:08:03,833{GMT}	INFO	[n1 stderr] maelstrom.process: Initalising: n1
2025-01-20 12:08:03,839{GMT}	INFO	[jepsen test runner] jepsen.core: Relative time begins now
2025-01-20 12:08:03,850{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:invoke	:echo	"Please echo 125"
2025-01-20 12:08:03,852{GMT}	INFO	[n1 stderr] maelstrom.process: Got: Please echo 125
2025-01-20 12:08:03,854{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:ok	:echo	{:echo "Please echo 125", :in_reply_to 1, :msg_id 1, :type "echo_ok"}
2025-01-20 12:08:04,047{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:invoke	:echo	"Please echo 110"
2025-01-20 12:08:04,048{GMT}	INFO	[n1 stderr] maelstrom.process: Got: Please echo 110
2025-01-20 12:08:04,048{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:ok	:echo	{:echo "Please echo 110", :in_reply_to 2, :msg_id 2, :type "echo_ok"}
2025-01-20 12:08:04,215{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:invoke	:echo	"Please echo 65"
2025-01-20 12:08:04,216{GMT}	INFO	[n1 stderr] maelstrom.process: Got: Please echo 65
2025-01-20 12:08:04,217{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:ok	:echo	{:echo "Please echo 65", :in_reply_to 3, :msg_id 3, :type "echo_ok"}
2025-01-20 12:08:04,292{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:invoke	:echo	"Please echo 28"
2025-01-20 12:08:04,293{GMT}	INFO	[n1 stderr] maelstrom.process: Got: Please echo 28
2025-01-20 12:08:04,293{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:ok	:echo	{:echo "Please echo 28", :in_reply_to 4, :msg_id 4, :type "echo_ok"}
2025-01-20 12:08:04,378{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:invoke	:echo	"Please echo 44"
2025-01-20 12:08:04,379{GMT}	INFO	[n1 stderr] maelstrom.process: Got: Please echo 44
2025-01-20 12:08:04,380{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:ok	:echo	{:echo "Please echo 44", :in_reply_to 5, :msg_id 5, :type "echo_ok"}
2025-01-20 12:08:04,533{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:invoke	:echo	"Please echo 57"
2025-01-20 12:08:04,534{GMT}	INFO	[n1 stderr] maelstrom.process: Got: Please echo 57
2025-01-20 12:08:04,535{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:ok	:echo	{:echo "Please echo 57", :in_reply_to 6, :msg_id 6, :type "echo_ok"}
2025-01-20 12:08:04,566{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:invoke	:echo	"Please echo 123"
2025-01-20 12:08:04,567{GMT}	INFO	[n1 stderr] maelstrom.process: Got: Please echo 123
2025-01-20 12:08:04,567{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:ok	:echo	{:echo "Please echo 123", :in_reply_to 7, :msg_id 7, :type "echo_ok"}
2025-01-20 12:08:04,667{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:invoke	:echo	"Please echo 20"
2025-01-20 12:08:04,669{GMT}	INFO	[n1 stderr] maelstrom.process: Got: Please echo 20
2025-01-20 12:08:04,669{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:ok	:echo	{:echo "Please echo 20", :in_reply_to 8, :msg_id 8, :type "echo_ok"}
2025-01-20 12:08:04,677{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:invoke	:echo	"Please echo 127"
2025-01-20 12:08:04,678{GMT}	INFO	[n1 stderr] maelstrom.process: Got: Please echo 127
2025-01-20 12:08:04,678{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:ok	:echo	{:echo "Please echo 127", :in_reply_to 9, :msg_id 9, :type "echo_ok"}
2025-01-20 12:08:04,726{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:invoke	:echo	"Please echo 25"
2025-01-20 12:08:04,727{GMT}	INFO	[n1 stderr] maelstrom.process: Got: Please echo 25
2025-01-20 12:08:04,728{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:ok	:echo	{:echo "Please echo 25", :in_reply_to 10, :msg_id 10, :type "echo_ok"}
2025-01-20 12:08:04,922{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:invoke	:echo	"Please echo 31"
2025-01-20 12:08:04,923{GMT}	INFO	[n1 stderr] maelstrom.process: Got: Please echo 31
2025-01-20 12:08:04,923{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:ok	:echo	{:echo "Please echo 31", :in_reply_to 11, :msg_id 11, :type "echo_ok"}
2025-01-20 12:08:04,979{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:invoke	:echo	"Please echo 60"
2025-01-20 12:08:04,980{GMT}	INFO	[n1 stderr] maelstrom.process: Got: Please echo 60
2025-01-20 12:08:04,981{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:ok	:echo	{:echo "Please echo 60", :in_reply_to 12, :msg_id 12, :type "echo_ok"}
2025-01-20 12:08:05,012{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:invoke	:echo	"Please echo 83"
2025-01-20 12:08:05,013{GMT}	INFO	[n1 stderr] maelstrom.process: Got: Please echo 83
2025-01-20 12:08:05,014{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:ok	:echo	{:echo "Please echo 83", :in_reply_to 13, :msg_id 13, :type "echo_ok"}
2025-01-20 12:08:05,051{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:invoke	:echo	"Please echo 53"
2025-01-20 12:08:05,051{GMT}	INFO	[n1 stderr] maelstrom.process: Got: Please echo 53
2025-01-20 12:08:05,052{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:ok	:echo	{:echo "Please echo 53", :in_reply_to 14, :msg_id 14, :type "echo_ok"}
2025-01-20 12:08:05,134{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:invoke	:echo	"Please echo 57"
2025-01-20 12:08:05,135{GMT}	INFO	[n1 stderr] maelstrom.process: Got: Please echo 57
2025-01-20 12:08:05,136{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:ok	:echo	{:echo "Please echo 57", :in_reply_to 15, :msg_id 15, :type "echo_ok"}
2025-01-20 12:08:05,283{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:invoke	:echo	"Please echo 103"
2025-01-20 12:08:05,284{GMT}	INFO	[n1 stderr] maelstrom.process: Got: Please echo 103
2025-01-20 12:08:05,285{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:ok	:echo	{:echo "Please echo 103", :in_reply_to 16, :msg_id 16, :type "echo_ok"}
2025-01-20 12:08:05,465{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:invoke	:echo	"Please echo 63"
2025-01-20 12:08:05,466{GMT}	INFO	[n1 stderr] maelstrom.process: Got: Please echo 63
2025-01-20 12:08:05,467{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:ok	:echo	{:echo "Please echo 63", :in_reply_to 17, :msg_id 17, :type "echo_ok"}
2025-01-20 12:08:05,604{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:invoke	:echo	"Please echo 124"
2025-01-20 12:08:05,605{GMT}	INFO	[n1 stderr] maelstrom.process: Got: Please echo 124
2025-01-20 12:08:05,605{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:ok	:echo	{:echo "Please echo 124", :in_reply_to 18, :msg_id 18, :type "echo_ok"}
2025-01-20 12:08:05,770{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:invoke	:echo	"Please echo 50"
2025-01-20 12:08:05,771{GMT}	INFO	[n1 stderr] maelstrom.process: Got: Please echo 50
2025-01-20 12:08:05,771{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:ok	:echo	{:echo "Please echo 50", :in_reply_to 19, :msg_id 19, :type "echo_ok"}
2025-01-20 12:08:05,877{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:invoke	:echo	"Please echo 71"
2025-01-20 12:08:05,878{GMT}	INFO	[n1 stderr] maelstrom.process: Got: Please echo 71
2025-01-20 12:08:05,879{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:ok	:echo	{:echo "Please echo 71", :in_reply_to 20, :msg_id 20, :type "echo_ok"}
2025-01-20 12:08:05,971{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:invoke	:echo	"Please echo 34"
2025-01-20 12:08:05,971{GMT}	INFO	[n1 stderr] maelstrom.process: Got: Please echo 34
2025-01-20 12:08:05,972{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:ok	:echo	{:echo "Please echo 34", :in_reply_to 21, :msg_id 21, :type "echo_ok"}
2025-01-20 12:08:06,155{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:invoke	:echo	"Please echo 37"
2025-01-20 12:08:06,156{GMT}	INFO	[n1 stderr] maelstrom.process: Got: Please echo 37
2025-01-20 12:08:06,157{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:ok	:echo	{:echo "Please echo 37", :in_reply_to 22, :msg_id 22, :type "echo_ok"}
2025-01-20 12:08:06,300{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:invoke	:echo	"Please echo 72"
2025-01-20 12:08:06,300{GMT}	INFO	[n1 stderr] maelstrom.process: Got: Please echo 72
2025-01-20 12:08:06,301{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:ok	:echo	{:echo "Please echo 72", :in_reply_to 23, :msg_id 23, :type "echo_ok"}
2025-01-20 12:08:06,416{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:invoke	:echo	"Please echo 96"
2025-01-20 12:08:06,416{GMT}	INFO	[n1 stderr] maelstrom.process: Got: Please echo 96
2025-01-20 12:08:06,417{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:ok	:echo	{:echo "Please echo 96", :in_reply_to 24, :msg_id 24, :type "echo_ok"}
2025-01-20 12:08:06,606{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:invoke	:echo	"Please echo 105"
2025-01-20 12:08:06,607{GMT}	INFO	[n1 stderr] maelstrom.process: Got: Please echo 105
2025-01-20 12:08:06,608{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:ok	:echo	{:echo "Please echo 105", :in_reply_to 25, :msg_id 25, :type "echo_ok"}
2025-01-20 12:08:06,761{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:invoke	:echo	"Please echo 65"
2025-01-20 12:08:06,762{GMT}	INFO	[n1 stderr] maelstrom.process: Got: Please echo 65
2025-01-20 12:08:06,762{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:ok	:echo	{:echo "Please echo 65", :in_reply_to 26, :msg_id 26, :type "echo_ok"}
2025-01-20 12:08:06,785{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:invoke	:echo	"Please echo 24"
2025-01-20 12:08:06,786{GMT}	INFO	[n1 stderr] maelstrom.process: Got: Please echo 24
2025-01-20 12:08:06,786{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:ok	:echo	{:echo "Please echo 24", :in_reply_to 27, :msg_id 27, :type "echo_ok"}
2025-01-20 12:08:06,855{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:invoke	:echo	"Please echo 90"
2025-01-20 12:08:06,856{GMT}	INFO	[n1 stderr] maelstrom.process: Got: Please echo 90
2025-01-20 12:08:06,857{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:ok	:echo	{:echo "Please echo 90", :in_reply_to 28, :msg_id 28, :type "echo_ok"}
2025-01-20 12:08:07,023{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:invoke	:echo	"Please echo 115"
2025-01-20 12:08:07,024{GMT}	INFO	[n1 stderr] maelstrom.process: Got: Please echo 115
2025-01-20 12:08:07,024{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:ok	:echo	{:echo "Please echo 115", :in_reply_to 29, :msg_id 29, :type "echo_ok"}
2025-01-20 12:08:07,040{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:invoke	:echo	"Please echo 93"
2025-01-20 12:08:07,041{GMT}	INFO	[n1 stderr] maelstrom.process: Got: Please echo 93
2025-01-20 12:08:07,042{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:ok	:echo	{:echo "Please echo 93", :in_reply_to 30, :msg_id 30, :type "echo_ok"}
2025-01-20 12:08:07,177{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:invoke	:echo	"Please echo 38"
2025-01-20 12:08:07,178{GMT}	INFO	[n1 stderr] maelstrom.process: Got: Please echo 38
2025-01-20 12:08:07,179{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:ok	:echo	{:echo "Please echo 38", :in_reply_to 31, :msg_id 31, :type "echo_ok"}
2025-01-20 12:08:07,352{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:invoke	:echo	"Please echo 79"
2025-01-20 12:08:07,353{GMT}	INFO	[n1 stderr] maelstrom.process: Got: Please echo 79
2025-01-20 12:08:07,354{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:ok	:echo	{:echo "Please echo 79", :in_reply_to 32, :msg_id 32, :type "echo_ok"}
2025-01-20 12:08:07,436{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:invoke	:echo	"Please echo 40"
2025-01-20 12:08:07,437{GMT}	INFO	[n1 stderr] maelstrom.process: Got: Please echo 40
2025-01-20 12:08:07,438{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:ok	:echo	{:echo "Please echo 40", :in_reply_to 33, :msg_id 33, :type "echo_ok"}
2025-01-20 12:08:07,567{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:invoke	:echo	"Please echo 60"
2025-01-20 12:08:07,568{GMT}	INFO	[n1 stderr] maelstrom.process: Got: Please echo 60
2025-01-20 12:08:07,568{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:ok	:echo	{:echo "Please echo 60", :in_reply_to 34, :msg_id 34, :type "echo_ok"}
2025-01-20 12:08:07,612{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:invoke	:echo	"Please echo 10"
2025-01-20 12:08:07,613{GMT}	INFO	[n1 stderr] maelstrom.process: Got: Please echo 10
2025-01-20 12:08:07,614{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:ok	:echo	{:echo "Please echo 10", :in_reply_to 35, :msg_id 35, :type "echo_ok"}
2025-01-20 12:08:07,713{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:invoke	:echo	"Please echo 40"
2025-01-20 12:08:07,714{GMT}	INFO	[n1 stderr] maelstrom.process: Got: Please echo 40
2025-01-20 12:08:07,715{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:ok	:echo	{:echo "Please echo 40", :in_reply_to 36, :msg_id 36, :type "echo_ok"}
2025-01-20 12:08:07,732{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:invoke	:echo	"Please echo 105"
2025-01-20 12:08:07,733{GMT}	INFO	[n1 stderr] maelstrom.process: Got: Please echo 105
2025-01-20 12:08:07,733{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:ok	:echo	{:echo "Please echo 105", :in_reply_to 37, :msg_id 37, :type "echo_ok"}
2025-01-20 12:08:07,774{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:invoke	:echo	"Please echo 109"
2025-01-20 12:08:07,775{GMT}	INFO	[n1 stderr] maelstrom.process: Got: Please echo 109
2025-01-20 12:08:07,776{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:ok	:echo	{:echo "Please echo 109", :in_reply_to 38, :msg_id 38, :type "echo_ok"}
2025-01-20 12:08:07,875{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:invoke	:echo	"Please echo 122"
2025-01-20 12:08:07,876{GMT}	INFO	[n1 stderr] maelstrom.process: Got: Please echo 122
2025-01-20 12:08:07,877{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:ok	:echo	{:echo "Please echo 122", :in_reply_to 39, :msg_id 39, :type "echo_ok"}
2025-01-20 12:08:07,889{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:invoke	:echo	"Please echo 90"
2025-01-20 12:08:07,890{GMT}	INFO	[n1 stderr] maelstrom.process: Got: Please echo 90
2025-01-20 12:08:07,891{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:ok	:echo	{:echo "Please echo 90", :in_reply_to 40, :msg_id 40, :type "echo_ok"}
2025-01-20 12:08:07,982{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:invoke	:echo	"Please echo 43"
2025-01-20 12:08:07,983{GMT}	INFO	[n1 stderr] maelstrom.process: Got: Please echo 43
2025-01-20 12:08:07,983{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:ok	:echo	{:echo "Please echo 43", :in_reply_to 41, :msg_id 41, :type "echo_ok"}
2025-01-20 12:08:07,999{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:invoke	:echo	"Please echo 4"
2025-01-20 12:08:08,000{GMT}	INFO	[n1 stderr] maelstrom.process: Got: Please echo 4
2025-01-20 12:08:08,000{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:ok	:echo	{:echo "Please echo 4", :in_reply_to 42, :msg_id 42, :type "echo_ok"}
2025-01-20 12:08:08,089{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:invoke	:echo	"Please echo 17"
2025-01-20 12:08:08,090{GMT}	INFO	[n1 stderr] maelstrom.process: Got: Please echo 17
2025-01-20 12:08:08,091{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:ok	:echo	{:echo "Please echo 17", :in_reply_to 43, :msg_id 43, :type "echo_ok"}
2025-01-20 12:08:08,280{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:invoke	:echo	"Please echo 94"
2025-01-20 12:08:08,281{GMT}	INFO	[n1 stderr] maelstrom.process: Got: Please echo 94
2025-01-20 12:08:08,281{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:ok	:echo	{:echo "Please echo 94", :in_reply_to 44, :msg_id 44, :type "echo_ok"}
2025-01-20 12:08:08,388{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:invoke	:echo	"Please echo 44"
2025-01-20 12:08:08,389{GMT}	INFO	[n1 stderr] maelstrom.process: Got: Please echo 44
2025-01-20 12:08:08,389{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:ok	:echo	{:echo "Please echo 44", :in_reply_to 45, :msg_id 45, :type "echo_ok"}
2025-01-20 12:08:08,438{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:invoke	:echo	"Please echo 121"
2025-01-20 12:08:08,439{GMT}	INFO	[n1 stderr] maelstrom.process: Got: Please echo 121
2025-01-20 12:08:08,439{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:ok	:echo	{:echo "Please echo 121", :in_reply_to 46, :msg_id 46, :type "echo_ok"}
2025-01-20 12:08:08,478{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:invoke	:echo	"Please echo 79"
2025-01-20 12:08:08,479{GMT}	INFO	[n1 stderr] maelstrom.process: Got: Please echo 79
2025-01-20 12:08:08,479{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:ok	:echo	{:echo "Please echo 79", :in_reply_to 47, :msg_id 47, :type "echo_ok"}
2025-01-20 12:08:08,511{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:invoke	:echo	"Please echo 121"
2025-01-20 12:08:08,512{GMT}	INFO	[n1 stderr] maelstrom.process: Got: Please echo 121
2025-01-20 12:08:08,512{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:ok	:echo	{:echo "Please echo 121", :in_reply_to 48, :msg_id 48, :type "echo_ok"}
2025-01-20 12:08:08,613{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:invoke	:echo	"Please echo 73"
2025-01-20 12:08:08,614{GMT}	INFO	[n1 stderr] maelstrom.process: Got: Please echo 73
2025-01-20 12:08:08,614{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:ok	:echo	{:echo "Please echo 73", :in_reply_to 49, :msg_id 49, :type "echo_ok"}
2025-01-20 12:08:08,798{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:invoke	:echo	"Please echo 58"
2025-01-20 12:08:08,798{GMT}	INFO	[n1 stderr] maelstrom.process: Got: Please echo 58
2025-01-20 12:08:08,799{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:ok	:echo	{:echo "Please echo 58", :in_reply_to 50, :msg_id 50, :type "echo_ok"}
2025-01-20 12:08:08,815{GMT}	INFO	[jepsen test runner] jepsen.core: Run complete, writing
2025-01-20 12:08:08,840{GMT}	INFO	[jepsen node n1] maelstrom.db: Tearing down n1
2025-01-20 12:08:09,809{GMT}	INFO	[jepsen node n1] maelstrom.net: Shutting down Maelstrom network
2025-01-20 12:08:09,809{GMT}	INFO	[jepsen test runner] jepsen.core: Analyzing...
2025-01-20 12:08:09,961{GMT}	INFO	[jepsen test runner] jepsen.core: Analysis complete
2025-01-20 12:08:09,966{GMT}	INFO	[jepsen results] jepsen.store: Wrote /home/stevan/src/maelstrom/store/echo/20250120T120801.962+0100/results.edn
2025-01-20 12:08:09,986{GMT}	INFO	[jepsen test runner] jepsen.core: {:perf {:latency-graph {:valid? true},
        :rate-graph {:valid? true},
        :valid? true},
 :timeline {:valid? true},
 :exceptions {:valid? true},
 :stats {:valid? true,
         :count 50,
         :ok-count 50,
         :fail-count 0,
         :info-count 0,
         :by-f {:echo {:valid? true,
                       :count 50,
                       :ok-count 50,
                       :fail-count 0,
                       :info-count 0}}},
 :availability {:valid? true, :ok-fraction 1.0},
 :net {:all {:send-count 102,
             :recv-count 102,
             :msg-count 102,
             :msgs-per-op 2.04},
       :clients {:send-count 102, :recv-count 102, :msg-count 102},
       :servers {:send-count 0,
                 :recv-count 0,
                 :msg-count 0,
                 :msgs-per-op 0.0},
       :valid? true},
 :workload {:valid? true, :errors ()},
 :valid? true}


Everything looks good! ヽ(‘ー`)ノ

real    0m12.901s
user    0m13.264s
sys     0m0.606s
```

Note that this is a language agnostic approach and the Maelstrom protocol can
easily be ported to any language.

## Conclusion

We've seen how to represent simple distributed programs and how to deploy them
and do actual I/O, in particular how to do messaging via `stdin` and `stdout`,
as well as how this functionality can be used to Jepsen test our programs via
Maelstrom.

The Maelstrom tests made 50 echo calls and they took around 13s. Next we'll
have a look at how we can test the same program but using simulation testing.
