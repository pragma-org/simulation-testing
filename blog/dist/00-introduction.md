# Introduction to simulation testing

This is a series of post about simulation testing. In this post, which
is the first in the series, we'll start by explaining the origins of and
motivation behind simulation testing, as well as give an overview of the
posts in the rest of the series.

## Metaphor

The fastest way, that I know of, to get the essence of the idea behind
simulation testing across is by means of a metaphor.

Imagine you are about to start building an aircraft. Even if you don't
know much about aeronautics (I certainly don't), I hope that you'll
agree that having access to a wind tunnel for testing purposes is
probably a good idea.

My reasoning is that being able to simulate harsh weather conditions,
such as a storm, without 1) having to waiting for one to happen in
nature and 2) risk losing your aircraft to the storm, in the case of
your construction not being solid enough, must be a massive time and
cost saver.

Simulation testing can be thought of as the wind tunnel equivalent for
distributed systems. It allows us to simulate and test under rare
network conditions, without having to wait for them to occur and without
risking to lose customer data.

## Background

Simulation testing was probably first popularised by Will Wilson in his
StrangeLoop 2014 [talk](https://www.youtube.com/watch?v=4fFDFbi3toc)[^1]
about how FoundationDB is tested. If you prefer reading, see the
FoundationDB
[documentation](https://apple.github.io/foundationdb/testing.html)
instead[^2].

In the talk Will explains that the team spent the first *two years*
building a custom C++ preprocessor and a simulator, before they
implemented the database using the custom language targeting the
simulation.

This first version didn't do any real networking or stable storage, all
networking and storage was simulated using in-memory data structures.

In fact all sources of non-deterministic are abstracted away and hidden
behind interfaces. These interfaces are then implemented by the
simulator. The simulator is parametrised by a seed for a deterministic
pseudo-random number generator (PRNG), which is used to introduce
randomness without breaking determinism. For example the order in which
messages arrive is controlled by the simulator and permuting the seed
can result in different message orders.

The PRNG can also be used to inject faults, e.g. every time a message
gets sent between the nodes in the system, roll a 100-sided die and if
we get 1, then don't deliver that message. Or every time we try to write
something to disk, don't write with some small probability. Or sometimes
crash a node, etc.

So the overall testing strategy is: generate random client requests,
introduce faults while serving the requests, make sure no assertions
fail while serving the requests, and potentially make some global
assertions across all nodes after the tests, e.g. all nodes have the
same data or the client requests and responses all linearise, etc. If
anything fails we can share the seed with out colleagues which can
reproduce the exact same test execution and outcome.

Once many such tests passed, FoundationDB introduced implementations of
interfaces that actually did real networking, storage, random number
generation and so on, which could then be deployed outside of the
simulation so to say.

What are the results from this kind of testing? Will
[said](https://antithesis.com/blog/is_something_bugging_you/):

> I think we only ever had one or two bugs reported by a customer. Ever.

Will continues saying:

> Kyle Kingsbury aka “aphyr” didn’t even bother testing it with Jepsen,
> because he didn’t think he’d find anything:

![Aphyr's tweet about testing
FoundationDB](https://antithesis.com/blog/is_something_bugging_you/images/aphyr_twitter_fdb.png)

Kyle has since said[^3] that that quote is a bit exaggerated and that
Jepsen can find problems that simulators miss, which makes sense given
that there can obviously be bugs in the simulator itself.

Simulation testing has since been adopted by other companies, in
particular Dropbox[^4] which in turn inspired TigerBeetleDB[^5]. Joran
Dirk Greef, TigerBeetle's CEO, has
[claimed](https://youtu.be/w3WYdYyjek4?t=849) that their simulation
testing helped them get the same confidence that would normal take 10
years to get for a consensus algorithm and storage engine using
conventional testing, within a single year, i.e. a 10x improvement how
fast the system can get production ready.

IOG also implemented simulation testing, but taking a seemingly
different approach to that of FoundationDB[^6].

As a final note, let me close by saying that the people behind
FoundationDB went on to found Antithesis and spent 5 years building a
language agnostic simulator by implementing a deterministic hypervisor.

## Related testing techniques

If you've done testing in the distributed systems space, then simulation
testing might remind you of:

- Property-based testing with a (state machine) model as oracle
- Chaos engineering
- Jepsen

These are all related to simulation testing. However the main difference
is that simulation testing is deterministic and "mocks" time, which
means that we can reproduce failures reliably and not have to wait for
timeouts to happen in real time (which speeds up testing).

We've already covered how we can achieve determinism, typically this
involves designing the system with simulation in mind from the ground
up, or a major refactor which abstracts away all non-determinism behind
interfaces.

Regarding speeding up time, this can be done in different ways. One way
is to do it like discrete-event simulators do:

1.  Each network message (or event more generally) gets assigned an
    arrival time;
2.  When the message is delivered by the simulator to the receiving
    node, the clock of the node is advanced to the arrival time;
3.  All timeouts and messages resulting from the timeouts triggering are
    collected by the simulator and assigned random arrival times;
4.  The message is then sent to the receiving node, any outgoing
    messages are again collected and assigned random arrival times by
    the simulator;
5.  The process repeats until there are no more client requests or some
    predetermined time T has passed.

Property-based testing typically doesn't involve fault-injection,
although there's nothing that stops one from adding it. Jepsen and Chaos
engineering always involve fault-injection, however not in deterministic
and reproducible way. For example, Jepsen will introduce network
partitions by using `iptables` to isolate nodes from each other. This is
so coarse grained that it will result in slightly different messages
being dropped, due to timing factors, where as with simulation testing
you can always drop a specific message deterministically.

## Plan for and overview of this series

Having explained what simulation testing is, its origins and how it's
different from other similar testing techniques, as well as highlighted
some uses of the technique in industry, we now have enough background to
explain what this series of posts is about.

The goal of this series of posts on simulation testing is to make the
technique more accessible. In particular we'd like to explain how
simulation testing works in a way that is:

- Language agnostic (can be ported to any language and capable of
  testing systems written in different languages);
- Easy to implement (in the order of a couple of days rather than a
  couple of years).

As far as I know no prior work has been done in this direction. Stay
tuned for the next post where we'll start by Jepsen testing a simple
echo node example as a warm up for then later simulation testing the
exact same example.

[^1]: Although there's an interesting reference in the (in)famous NATO
    software engineering
    [conference](http://homepages.cs.ncl.ac.uk/brian.randell/NATO/nato1968.PDF)
    (1968), in "4.3.3. FEEDBACK THROUGH MONITORING AND SIMULATION" (p.
    31 in the PDF):

    Alan Perlis says:

    > "I'd like to read three sentences to close this issue.
    >
    > 1.  A software system can best be designed if the testing is
    >     interlaced with the designing instead of being used after the
    >     design.
    >
    > 2.  A simulation which matches the requirements contains the
    >     control which organizes the design of the system.
    >
    > 3.  Through successive repetitions of this process of interlaced
    >     testing and design the model ultimately becomes the software
    >     system itself. I think that it is the key of the approach that
    >     has been suggested, that there is no such question as testing
    >     things after the fact with simulation models, but that in
    >     effect the testing and the replacement of simulations with
    >     modules that are deeper and more detailed goes on with the
    >     simulation model controlling, as it were, the place and order
    >     in which these things are done."

[^2]: Other posts about simulation testing that are worth reading
    include:

    - Tyler Neely's [post](https://sled.rs/simulation.html) instead;
    - Phil Eaton's
      [post](https://notes.eatonphil.com/2024-08-20-deterministic-simulation-testing.html).

[^3]: I can't find the reference right now.

[^4]: Dropbox has written two posts about it:

    1.  <https://dropbox.tech/infrastructure/rewriting-the-heart-of-our-sync-engine>
    2.  <https://dropbox.tech/infrastructure/-testing-our-new-sync-engine>

[^5]: Tigerbeetle has several videos about their simulation testing:

    1.  [TigerStyle! (Or How To Design Safer Systems in Less
        Time)](https://www.youtube.com/watch?v=w3WYdYyjek4) by Joran
        Dirk Greef (Systems Distributed, 2023);
    2.  Joran Dirk Greef's talk [SimTigerBeetle (Director's
        Cut)](https://www.youtube.com/watch?v=Vch4BWUVzMM) (2023);
    3.  Aleksei "matklad" Kladov's talk [A Deterministic Walk Down
        TigerBeetle’s main() Street](https://youtu.be/AGxAnkrhDGY) (P99
        CONF, 2023) .

[^6]: IOG published a
    [paper](http://www.cse.chalmers.se/~rjmh/tfp/proceedings/TFP_2020_paper_11.pdf)
    called "Flexibility with Formality: Practical Experience with Agile
    Formal Methods in Large-Scale Functional Programming" (2020), where
    they write:

    > "Both the network and consensus layers must make significant use
    > of concurrency which is notoriously hard to get right and to test.
    > We use Software Transactional Memory (STM) to manage the internal
    > state of a node. While STM makes it much easier to write correct
    > concurrent code, it is of course still possible to get wrong,
    > which leads to intermittent failures that are hard to reproduce
    > and debug.
    >
    > In order to reliably test our code for such concurrency bugs, we
    > wrote a simulator that can execute the concurrent code with both
    > timing determinism and giving global observability, producing
    > execution traces. This enables us to write property tests that can
    > use the execution traces and to run the tests in a deterministic
    > way so that any failures are always reproducible. The use of the
    > mini-protocol design pattern, the encoding of protocol
    > interactions in session types and the use of a timing reproducable
    > simulation has yielded several advantages:
    >
    > - Adding new protocols (for new functionality) with strong
    >   assurance that they will not interact adversly with existing
    >   functionality and/or performance consistency.
    >
    > - Consistent approaches (re-usable design approaches) to issues of
    >   latency hiding, intra mini-protocol flow control and timeouts /
    >   progress criteria.
    >
    > - Performance consistent protocol layer abstraction / subsitution:
    >   construct real world realistic timing for operation without
    >   complexity of simulating all the underlying layer protocol
    >   complexity. This helps designs / development to maintain
    >   performance target awareness during development.
    >
    > - Consitent error propagation and mitigation (mini protocols to a
    >   peer live/die together) removing issues of resource lifetime
    >   management away from mini-protocol designers / implementors."

    The simulation code is open source and can be found
    [here](https://github.com/input-output-hk/io-sim).
