## 18-30th Jan 2025

Had a meeting with Arnaud about connecting my simulation testing work
with his consensus work. Here's a diagram of the main components of the
simulation testing:

  https://excalidraw.com/#room=7b2a8ed11b568e50603a,YmrFWAZQCKBIiTee5KkhGg

We also looked at Arnaud's "naive block selection" PR:

  https://github.com/pragma-org/amaru/pull/75

As well as my code so far:

  https://github.com/pragma-org/simulation-testing/tree/main/moskstraumen/src/Moskstraumen

Here are some of my post-meeting thoughts (where you = Arnaud):

I thought a bit about a, and I think an argument against something like
madsim is: if you rely on it, then something equivalent must exist
in other SUT languages, i.e. Go, TypeScript, etc. You could argue
that Haskell has io-sim, but I'm sure it works quite differently to
madsim, so now you have an integration problem between "async runtime"
(e.g. tokio + madsim) and the simulation testing (request generation,
state machine model checking, LTL liveness checking, etc). What I
mean is that connecting this "async runtime" with the simulation
testing will look slightly different for each programming language
(assuming that there exists something madsim-like to begin with).

Furthermore, if we use different "madsim"s in different languages,
it's going to be a pita to understand those libraries and extend them
to our needs. io-sim is a good example of this problem.

That's why I propose to create a simple deterministic event loop
(i.e. "async runtime"), which by construction integrates well with
the simulation and make that easily portable to whatever SUT language
using whatever concurrency primitives are available there. That way
we own this core part. I know you're worried about having to maintain
a language, but I'd like to stress that the Maelstrom language is
small and has already been ported to many different languages
(including Rust, Go and JavaScript):

  https://github.com/jepsen-io/maelstrom/tree/main/demo

We can't just use those implementations though, because they are not
necessarily deterministic. But still I'd say it's fairly conservative
in terms of effort. Also like I said, if we can leverage the examples
that Maelstrom already has, but simulation test them instead Jepsen's
black box tests, and show that we can get a massive speed up in terms
of test execution due to simulated time, then we've are in a good spot
(both in terms of testing consensus, but also to explain the benefit
vs the industry standard aka Jepsen).

How to make this event loop performant is a separate issue. I think
the key is Disruptor pipelining, rather than SEDA/gasket, because the
former is deterministic while the latter isn't. Medium term SEDA can
be run with worker pool size of 1, to avoid non-determinism. Longer
term, we probably want to make gasket use Disruptors instead. Immediate
term, like I said, none of this matters because Jepsen/Maelstrom
doesn't rely on determinism, so it's fine.

Btw I've thought and written on the topic of deterministic pipelining
(or an event loop that uses parallelism) over here:

  https://stevana.github.io/parallel_stream_processing_with_zero-copy_fan-out_and_sharding.html
  https://stevana.github.io/scheduling_threads_like_thomas_jefferson.html

Both posts mentions SEDA (which gasket is based upon).

Anyhow it seemed like you are only artificially using gasket
stages currently, and the four stages can be combined using function
composition into one stage. My current event loop can be thought of
as a one stage pipeline, so that part should be fine for now as well
(until we figure out how extend the event loop with Disruptors and
properly parallelise the stages).

Regarding your comment about parallelising the whole simulation
itself. A while ago I asked one of the guys from Antithesis how they
do it, and he said they simply generate N seeds and run N simulations in
parallel completely independent from each other, because of randomness,
they'll likely not test the same paths so much. One could try to be
more fancy and remember which seeds have been tested with already
and avoid those, e.g. using a shared bloom filter across the N
simulations, but this something we can think about later.

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


