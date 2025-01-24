## 17-23rd Jan 2025

The main highlight this week is that I finished the simulation testing
[introduction](https://github.com/pragma-org/simulation-testing/blob/main/blog/src/00-introduction.md),
which explains what I'm working on and what the current plan is.

I had a couple of meetings this week. The first one with Arnaud, where I showed
what I got so far and what the plan is, and he seems to agree that it's the
right way forward. The second was an onboarding with the team, were I got a bit
of background about everyone, and this year's milestones and budget was also
shared. Finally, I joined the Amaru maintainer committee, it was very short
because most people were away, but Damien asked if I could show something for
the next demo day and I said I could.

Otherwise I've been continuing to extend the "node language" to add more
features that Maelstrom has. This week I added timeouts for RPC calls, periodic
timers and synchronous RPC calls (this is something that Arnaud also seemed to
need). 

To test that these constructs work I implement the Maelstrom examples
(broadcast, CRDT and key-value store) and run the Maelstrom tests. The
key-value store example is still failing on the second part. Once the key-value
store is done, there's one final Maelstrom example (raft), once that's done the
"node language" should be expressive enough. The effort can then shift to
simulating this language (as opposed to deploying it and using Maelstrom). The
Maelstrom results will be used as sanity checks, as well as coverage and
performance baseline.

Next I hope to document how these Maelstrom examples work and show how
simulation testing can be 1000x faster.

## 9-16th Jan 2025

I started working on a simulation testing library/framework that can be used
for testing the consensus nodes written in Haskell, Go, TypeScript and Rust (or
any other language).

For those unfamiliar with simulation testing, see Will Wilson's Strange Loop
2014 [talk](https://www.youtube.com/watch?v=4fFDFbi3toc) or if you prefer
reading have a look at Tyler Neely's [post](https://sled.rs/simulation.html).

I say library/framework, because I hope that it can be used as both. My goal is
to keep it as small as possible, break it up in stages and document how to
implement each stage in about an afternoon. So the idea is that it should be
possible to port the test library to any other language. But it's also a
framework in that you can test node written in a different programming language
via IPC. 

For example the current
[prototype](https://github.com/pragma-org/simulation-testing/moskstraumen/)
that I got is written in Haskell, so I want to be able to import the Haskell
consensus node and test it as a library all in one process. But I also want to
be able to spawn a Rust consensus node and let the test communicate with it via
a pipe (or whatever IPC mechanism), in which case it feels more like a
framework with one process per node. It should also be easy to mix the two,
i.e. test nodes implemented in different languages against each other.

So far I've implemented a small language for writing distributed system nodes.
It's the same language that is used in Jepsen's Maelstrom, which allows for
sending messages, replying, making rpc calls and setting timers.

For those who don't know, Maelstrom was used in a series of distributed systems
challenges designed by [Kyle Kingsbury](https://github.com/jepsen-io/maelstrom)
and [Fly.io](https://fly.io/dist-sys/). It's basically a small framework where
you write your nodes in the small language I mentioned above, and then Jepsen
is used to generate traffic and check the correctness with respect to some
workload/model. Maelstrom spawns the nodes in separate process and uses pipes
to stdin and stdout to send and receive messages to the nodes.

So I've done the same, except I've added an interface between the test driver
and the nodes which can be implemented using pipes, or any other IPC mechanism,
or even bypassing the networking and encoding/decoding of messages completely
if used as a in process library.

The other major difference between what I've done and Maelstrom is that the
simulator that is used to drive the tests is completely deterministic, while
Jepsen (which backs Maelstrom) isn't. Determinism is important for reproducible
test results as well as test case minimisation aka shrinking (which is
something Jepsen cannot do).

Yet another difference is that the simulator can also simulate the passage of
time, which means we don't have to wait for timeouts to happen. Jepsen has to
wait for timeouts in real time, which slows down the tests considerably. It
also cannot be used as a library in-process, which adds additional overhead for
networking and message encoding/decoding.

So far I've implemented enough of the node language to be able to do the two
echo and broadcast (part 1) challenges in Maelstrom. My plan is to implement
all of them and test the nodes that I implement first using Maelstrom and then
test the same node without changing any code using the simulator. This gives us
a baseline for what coverage and testing speed that we can then try to improve
upon!


