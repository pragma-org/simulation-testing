---
author: Stevan A
date: 2025-02-06
---

# Using Maelstrom to test distributed systems

In the [previous
post](https://github.com/pragma-org/simulation-testing/blob/main/blog/src/00-introduction.md)
we introduced simulation testing. 

Before we start developing the pieces we need to do simulation testing, let's
first have a look at how more "traditional" testing of distributed systems
looks like.

In order to get started with any testing we first need to have some distributed
system to test.

## First example: echo

Let's consider a simple distributed system: a node which echos back whatever
message one sends to it.

In pseudo code we can define our echo node like this:

```
node (Echo text) = reply (Echo_ok text)
```

Where `Echo` and `Echo_ok` are tags which let's us distinguish messages and
`text` is some arbitrary string. The `reply` construct can be used to respond
to the sender of the message.

Notice how we've abstracted away any kind of networking. There's no IP
addresses, sockets, or anything like that. The pseudo code captures the essence
of what the node is supposed to do, echo back the message it gets, and nothing
else.

## Sketching how to test echo

How can we ensure that our echo node works as intended? 

Given how trivial the example is, it might almost seem unnecessary, but since
the testing setup is the same as for more complicated examples it's still
worthwhile stepping stone.

Here's an idea: imagine if we could spawn nodes as processes and then use
`stdin` to send messages to them and have them reply to `stdout`. 

In pseudo code:

```
main = stdio node
```

Where `stdio` does the reading on `stdin`, decodes the bytes into the echo
message type, applies the message to `node`, encodes the reply back to bytes,
and finally writes the response back to `stdout`.

If we compiled the above main function to a binary, called `echo-example`, we
could run it as follows in a terminal: 

```bash
$ echo '{"type": "echo", "text": "hi"}' | echo-example
{"type": "echo_ok", "text": "hi"}
```

(Here we are using a JSON codec for our messages, but any serialisation format
will do.)

Using this principle one could create more elaborate tests by generating many
random requests to the nodes and record all replies, then afterwards we could
check that for each `Echo` message there's a corresponding `Echo_ok` reply.

This testing idea happens to be exactly what Jepsen's sister project,
[Maelstrom](https://github.com/jepsen-io/maelstrom), implements.

## Echo example in Maelstrom

We've already explained the main idea behind the testing strategy of Maelstrom
above.

To get a better feel for how it works, let's just download and run it.

```bash
wget https://github.com/jepsen-io/maelstrom/releases/download/v0.2.4/maelstrom.tar.bz2
tar xf maelstrom.tar.bz2
cd maelstrom
```

In the release that we just downloaded and unpacked, there's a demo directory
which also happens to contain a concrete implementation of the echo example
which we've sketched the pseudo code of above.

Let's have a look at how echo is implemented in Ruby.

```ruby
class EchoServer
  def main!
    STDERR.puts "Online"

    while line = STDIN.gets
      req = JSON.parse line, symbolize_names: true
      STDERR.puts "Received #{req.inspect}"

      body = req[:body]
      case body[:type]
        # Essence of echo.
        when "echo"
          STDERR.puts "Echoing #{body}"
          reply! req, {type: "echo_ok", echo: body[:echo]}
      end
    end
  end

  def reply!(request, body)
    msg = {body: body}
    JSON.dump msg, STDOUT
    STDOUT << "\n"
    STDOUT.flush
  end
end

EchoServer.new.main!
```

I hope the above is relatively easy to follow and corresponds almost one-to-one
with the pseudo code we sketched before.

One thing to note is that the structure of the main function will be the same
for other examples, so Maelstrom provides a node abstraction which let's us
merely write the block that below the comment "essence of echo". Here's the
echo example using the node abstraction:

```ruby
class EchoNode
  def initialize
    @node = Node.new

    @node.on "echo" do |msg|
      @node.reply! msg, msg[:body].merge(type: "echo_ok")
    end
  end

  def main!
    @node.main!
  end
end

EchoNode.new.main!
```

Basically the node abstraction does what `stdio` did in our pseudo code, i.e.
takes care of the reading and writing to `stdin` and `stdout` as well as the
encoding and decoding to JSON.

## Testing the echo example using Maelstrom

Now that we have a concrete version of our echo node, let's look at how we can
use Maelstrom to test it.

First we need to install the run-time dependencies of Maelstrom. If you're
using Nix, the following will do the trick:

```bash
cat << EOF > shell.nix
let
  nixpkgs = fetchTarball "https://github.com/NixOS/nixpkgs/archive/refs/tags/24.05.tar.gz";
  pkgs = import nixpkgs { config = {}; overlays = []; };
in

# https://github.com/jepsen-io/maelstrom/blob/main/doc/01-getting-ready/index.md#prerequisites
pkgs.mkShell {
  packages = with pkgs; [
    openjdk
    graphviz
    gnuplot
    ruby
  ];
}
EOF

nix-shell
```

Otherwise see the following
[instructions](https://github.com/jepsen-io/maelstrom/blob/main/doc/01-getting-ready/index.md#prerequisites).

With the dependencies installed, we can test the echo example as follows.

```bash
$ time ./maelstrom test --workload echo --bin demo/ruby/echo.rb --time-limit 5 --log-stderr --rate 10 --nodes n1
[...]
2025-01-20 12:08:03,802{GMT}	INFO	[jepsen node n1] maelstrom.net: Starting Maelstrom network
2025-01-20 12:08:03,803{GMT}	INFO	[jepsen test runner] jepsen.db: Tearing down DB
2025-01-20 12:08:03,804{GMT}	INFO	[jepsen test runner] jepsen.db: Setting up DB
2025-01-20 12:08:03,806{GMT}	INFO	[jepsen node n1] maelstrom.service: Starting services: (lin-kv lin-tso lww-kv seq-kv)
2025-01-20 12:08:03,807{GMT}	INFO	[jepsen node n1] maelstrom.db: Setting up n1
2025-01-20 12:08:03,808{GMT}	INFO	[jepsen node n1] maelstrom.process: launching ./demo/ruby/echo.rb []
2025-01-20 12:08:03,833{GMT}	INFO	[n1 stderr] maelstrom.process: Initalising: n1
2025-01-20 12:08:03,839{GMT}	INFO	[jepsen test runner] jepsen.core: Relative time begins now
2025-01-20 12:08:03,850{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:invoke	:echo	"Please echo 125"
2025-01-20 12:08:03,852{GMT}	INFO	[n1 stderr] maelstrom.process: Got: Please echo 125
2025-01-20 12:08:03,854{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:ok	:echo	{:echo "Please echo 125", :in_reply_to 1, :msg_id 1, :type "echo_ok"}
2025-01-20 12:08:04,047{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:invoke	:echo	"Please echo 110"
2025-01-20 12:08:04,048{GMT}	INFO	[n1 stderr] maelstrom.process: Got: Please echo 110
2025-01-20 12:08:04,048{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:ok	:echo	{:echo "Please echo 110", :in_reply_to 2, :msg_id 2, :type "echo_ok"}
[...]
2025-01-20 12:08:08,798{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:invoke	:echo	"Please echo 58"
2025-01-20 12:08:08,798{GMT}	INFO	[n1 stderr] maelstrom.process: Got: Please echo 58
2025-01-20 12:08:08,799{GMT}	INFO	[jepsen worker 0] jepsen.util: 0	:ok	:echo	{:echo "Please echo 58", :in_reply_to 50, :msg_id 50, :type "echo_ok"}
2025-01-20 12:08:08,815{GMT}	INFO	[jepsen test runner] jepsen.core: Run complete, writing
2025-01-20 12:08:08,840{GMT}	INFO	[jepsen node n1] maelstrom.db: Tearing down n1
2025-01-20 12:08:09,809{GMT}	INFO	[jepsen node n1] maelstrom.net: Shutting down Maelstrom network
2025-01-20 12:08:09,809{GMT}	INFO	[jepsen test runner] jepsen.core: Analyzing...
2025-01-20 12:08:09,961{GMT}	INFO	[jepsen test runner] jepsen.core: Analysis complete
2025-01-20 12:08:09,966{GMT}	INFO	[jepsen results] jepsen.store: Wrote ./store/latest/results.edn
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

I've edited the output to keep it brief. From the `:stats` we can see that
there were actually 50 echo requests generated by the tests.

Maelstrom finishes by saying that everything looks good, and the whole test
takes about 10 seconds.

What exactly is it that's being tested though? In order to answer this question
we need to understand what the `--workload echo` flag does.

## Maelstrom workloads

A workload is essentially two things. First a way to generate messages, see
`:generator` below.

```clojure
(defn workload
  "Constructs a workload for linearizable registers, given option from the CLI
  test constructor:

      {:net     A Maelstrom network}"
  [opts]
  {:client    (client (:net opts))
   :generator (->> (fn []
                     {:f      :echo
                      :value  (str "Please echo " (rand-int 128))})
                   (gen/each-thread))
   :checker   (checker)})
```

We see that in this case we generate "Please echo" followed by a random integer
between 0 and 128. If we scroll back up to the test output we see that this is
indeed the format.

The second part of a workload is a so called checker. In the echo case the
checker essentially pairs up requests and responses (using
`history/pair-index`), and then ensures that the echoed message (the random
integer) is the same in the request and the response.

```clojure
(defn checker
  "Expects responses to every echo operation to match the invocation's value."
  []
  (reify checker/Checker
    (check [this test history opts]
      (let [pairs (history/pair-index history)
            errs  (keep (fn [[invoke complete]]
                          (cond ; Only take invoke/complete pairs
                                (not= (:type invoke) :invoke)
                                nil

                                (not= (:value invoke)
                                      (:echo (:value complete)))
                                ["Expected a message with :echo"
                                 (:value invoke)
                                 "But received"
                                 (:value complete)]))
                          pairs)]
        {:valid? (empty? errs)
         :errors errs}))))
```

In the test output at the end we can see `:workload {:valid? true, :errors
()}`, which is the result of running the above checker.

As a final remark, it should be pointed out that generators and checkers are
part of Jepsen and in fact Maelstrom is using Jepsen under the hood. In a sense
Maelstrom can be seen as a platform for developing distributed systems which
makes it particularly convenient to run Jepsen tests on the system being
developed.

## Conclusion and what's next

We've seen how to represent simple distributed programs and how to deploy them
and do actual I/O, in particular how to do messaging via `stdin` and `stdout`,
as well as how this functionality can be used to test our programs via
Maelstrom.

The Maelstrom tests made 50 echo calls and they took around 10s. Also worth
noting is that the Maelstrom tests are non-deterministic and cannot shrink the
input in case it finds an error[^1]. This means that if we manage to find an
error, it might not be easy to reproduce it. This is annoying because it makes
it difficult to share a failing test with someone or to test if a patch
actually fixes an error that we found.

One cool thing about Maelstrom is that it's language agnostic. The Maelstrom
protocol can easily be ported to any language that supports stdio. At the time
of writing, the Maelstrom repository contains ports to eight languages, and one
can find even more unofficial ports elsewhere.

For more on Maelstrom see the official
[documentation](https://github.com/jepsen-io/maelstrom?tab=readme-ov-file#documentation)
as well as [Fly.io's](https://fly.io/dist-sys/) distributed systems challenges.

Next up in our series of posts we shall begin our journey towards simulation
testing, by taking the Maelstrom protocol and implementing it in a completely
deterministic way. We'll then re-implement the message generation part of
workloads to be completely deterministic as well. Since execution of the tests
will be deterministic, we can also implement shrinking and present small
counterexamples.

[^1]: It can still show small counterexamples using the [Elle
    checker](https://github.com/jepsen-io/elle). These are not counterexamples
    are not found by shrinking the inputs like in property-based testing, but
    rather by trying to find cycles in the transactions. (Personally I find
    these cycle counterexamples less intuitive than shrunk inputs.)
