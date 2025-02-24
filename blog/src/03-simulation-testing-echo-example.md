---
author: Stevan A
date: 2025-02-12
---

# Sketching how to simulation test distributed systems

In the [last post](02-maelstrom-testing-echo-example.md) we saw how to test a
simple distributed system, a node that echos back the requests it gets, using
Jepsen via Maelstrom.

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
implementation of the runtime, there's no non-determinism.

So let's dig a layer deeper and have a look at how this node runtime is
implemented.

```go
// Node represents a single node in the network.
type Node struct {
    wg sync.WaitGroup

    handlers  map[string]HandlerFunc

    // Stdin is for reading messages in from the Maelstrom network.
    Stdin io.Reader

    // Stdout is for writing messages out to the Maelstrom network.
    Stdout io.Writer
}

// NewNode returns a new instance of Node connected to STDIN/STDOUT.
func NewNode() *Node {
    return &Node{
        handlers:  make(map[string]HandlerFunc),

        Stdin:  os.Stdin,
        Stdout: os.Stdout,
    }
}
```

Given the above, we can implement `Handle` by simply adding a new handler
function:

```go
// Handle registers a message handler for a given message type. Will panic if
// registering multiple handlers for the same message type.
func (n *Node) Handle(typ string, fn HandlerFunc) {
    if _, ok := n.handlers[typ]; ok {
        panic(fmt.Sprintf("duplicate message handler for %q message type", typ))
    }
    n.handlers[typ] = fn
}
```

Again, all still deterministic. It's only in the `Run` function where the
non-determinism creeps in:

```go
// Run executes the main event handling loop. It reads in messages from STDIN
// and delegates them to the appropriate registered handler. This should be
// the last function executed by main().
func (n *Node) Run() error {
    scanner := bufio.NewScanner(n.Stdin)
    for scanner.Scan() {
        line := scanner.Bytes()

        // Parse next line from STDIN as a JSON-formatted message.
        var msg Message
        if err := json.Unmarshal(line, &msg); err != nil {
            return fmt.Errorf("unmarshal message: %w", err)
        }

        var body MessageBody
        if err := json.Unmarshal(msg.Body, &body); err != nil {
            return fmt.Errorf("unmarshal message body: %w", err)
        }
        log.Printf("Received %s", msg)

        // Handle message in a separate goroutine.
        n.wg.Add(1)
        go func() {
            defer n.wg.Done()
            n.handleMessage(h, msg)
        }()
    }
    if err := scanner.Err(); err != nil {
        return err
    }

    // Wait for all in-flight handlers to complete.
    n.wg.Wait()

    return nil
}
```

Can you spot the problem?

It's in the block of code which has the comment "Handle message in a separate
goroutine". To test this, let's introduce some jitter to simulate that the
execution of handlers could take different amount of time (perhaps due to some
messages requiring more computation than others, or because of being unlucky
with the garbage collection, etc):

```diff
  // Handle message in a separate goroutine.
  n.wg.Add(1)
  go func() {
          defer n.wg.Done()
+         rand.Seed(time.Now().UnixNano())
+         // Sleep for 0 to 10 ms
+         randomSleepTime := time.Duration(rand.Intn(11)) * time.Millisecond
+         time.Sleep(randomSleepTime)
          n.handleMessage(h, msg)
  }()
```

If we run the echo example with the above modification and send it two massages
concurrently to `stdin`:

```bash
 maelstrom-echo < <(echo '{"body":{"type":"echo", "echo": "hi_1"}}' & \
                    echo '{"body":{"type":"echo", "echo": "hi_2"}}')
```

We see that sometimes we get the messages echoed back in the same order as they
were received:

```
2025/02/07 12:21:01 Received {  {"type":"echo", "echo": "hi_2"}}
2025/02/07 12:21:01 Received {  {"type":"echo", "echo": "hi_1"}}
2025/02/07 12:21:01 Sent {"body":{"echo":"hi_2","in_reply_to":0,"type":"echo_ok"}}
{"body":{"echo":"hi_2","in_reply_to":0,"type":"echo_ok"}}
2025/02/07 12:21:01 Sent {"body":{"echo":"hi_1","in_reply_to":0,"type":"echo_ok"}}
{"body":{"echo":"hi_1","in_reply_to":0,"type":"echo_ok"}}
```

But sometimes not:

```
2025/02/07 12:20:03 Received {  {"type":"echo", "echo": "hi_2"}}
2025/02/07 12:20:03 Received {  {"type":"echo", "echo": "hi_1"}}
2025/02/07 12:20:03 Sent {"body":{"echo":"hi_1","in_reply_to":0,"type":"echo_ok"}}
{"body":{"echo":"hi_1","in_reply_to":0,"type":"echo_ok"}}
2025/02/07 12:20:03 Sent {"body":{"echo":"hi_2","in_reply_to":0,"type":"echo_ok"}}
{"body":{"echo":"hi_2","in_reply_to":0,"type":"echo_ok"}
```

Clearly we've exaggerated the non-determinism with the random sleep, but I hope
you agree that it's there even without the sleep and it can happen.

At this point you might be wondering: why do we handle messages in separate
goroutines to being with? Can't we just handle it in the main thread? For the
simple echo example we can, but in order to be able to express more complicated
examples we need some kind of concurrency[^2].

Now there are other ways to achieve concurrency than with threads (or goroutines).

Kyle Kingsbury, the main author of Jepsen and Maelstrom, writes in the
Maelstrom docs:

> "We could write this as a single-threaded event loop, using fibers or
> co-routines, or via threads, but for our purposes, threads will simplify a good
> deal. Multi-threaded access means we need a lock--preferably re-entrant--to
> protect our IO operations, assigning messages, and so on. We'll want one for
> logging to STDERR too, so that our log messages don't get mixed up."

With "good deal", my guess what Kyle means is: it's the least amount of effort,
and since Jepsen and Maelstrom are non-deterministic anyway it doesn't matter
that we are introducing non-determinism in the node runtime.

What if we tried to use some of the other ways of achieving concurrency that
Kyle lists. For example, a single-threaded event loop can be made
deterministic!

## The non-determinism of Jepsen and, by extension, Maelstrom

We've seen how the existing Maelstrom Go and Ruby runtimes are
non-deterministic, and we've got an idea of how to fix this using a
single-thread event loop.

However even if we did so, we still wouldn't get deterministic tests. The
reason for this that Jepsen itself isn't deterministic.

We saw an example of this in our previous post, when we defined the generator
for the requests for the echo example:

```clojure
   :generator (->> (fn []
                     {:f      :echo
                      :value  (str "Please echo " (rand-int 128))})
                   (gen/each-thread))
```

That `rand-int` will produce random integers every time it's run, thus breaking
determinism. We could fix this by making the seed for the pseudo-random number
generator a parameter and thus get the same random integers given the same seed,
but there are many more places Jepsen uses
[non-determinism](https://github.com/jepsen-io/jepsen/issues/578).

So rather than trying to patch Jepsen, and introducing Jepsen and Clojure as a
dependencies, let's just re-implement the test case generation, message
scheduling and checking machinery from scratch.

This might seem like a lot of work, but recall that property-based testing
essentially provides all we need, and I've written about how we can implement
property-based testing from scratch in the
[past](https://stevana.github.io/the_sad_state_of_property-based_testing_libraries.html).

By staying closer to property-based testing we get shrinking (minimised
counterexamples) for cheap as well, thereby fixing all the cons we identified
with the Maelstrom approach. In fact good shrinking depends on determinism, so
the two go are related.

## Conclusion and what's next

We've located the sources of non-determinism in the Maelstrom tests from the
last post and sketched how we can swap out these components for deterministic
ones.

Next we'll start on the actual implementation for the deterministic simulation
testing.


[^1]: Could be a blessing but more likely it's a curse.

[^2]: For example, imagine we got some periodic tasks that need to be performed
    at some time interval, these need to be done concurrently and not be forced
    to wait became the node is busy processing messages from `stdin`. We'll
    come back to timers and other concurrent constructs in more detail later.
