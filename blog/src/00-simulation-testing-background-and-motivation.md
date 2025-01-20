# Simulation testing

This is a series of post about simulation testing. In this post, which is the
first in the series, we'll start by giving explaining the origins and
motivation of simulation testing.

## Metaphor

I know nothing about building airplanes, but I could imagine that having access
to a wind tunnel when building an airplane could be useful. Being able to
simulate harsh conditions, such as a storm, without waiting for one to happen
in nature must be a massive time saver.

Simulation testing can be thought of as the wind tunnel equivalent for
distributed systems. It allows us to simulate and test under rare network
conditions, without having to wait for them to occur.

## Background

Simulation testing was probably first popularised by Will Wilson in his
StrangeLoop 2014 [talk](https://www.youtube.com/watch?v=4fFDFbi3toc)[^1] about
how FoundationDB is tested.

If you prefer reading, see the FoundationDB
[documentation](https://apple.github.io/foundationdb/testing.html) or Tyler
Neely's [post](https://sled.rs/simulation.html) instead.

## Related testing techniques

* Property-based testing with a (state machine) model as oracle
* Chaos testing
* Jepsen

The main difference is that simulation testing is deterministic and "mocks"
time, which means that we can reproduce failures reliably and not have to wait
for timeouts to happen in real time (which speeds up testing).

## Uses in industry

* FoundationDB
* Dropbox
  + https://dropbox.tech/infrastructure/rewriting-the-heart-of-our-sync-engine
  + https://dropbox.tech/infrastructure/-testing-our-new-sync-engine
* Tigerbeetle
  + https://youtu.be/AGxAnkrhDGY
* Antithesis

## Other posts

* https://notes.eatonphil.com/2024-08-20-deterministic-simulation-testing.html

## Conclusion

Having explained what simulation testing is, explained its origins and how it's
different from other similar testing techniques, as well as highlighted some
uses of the technique in industry, we are ready to move on to the next part
where we'll give an overview of the rest of the series of posts on simulation
testing.


[^1]: Although there's an interesting reference in the (in)famous NATO software
    engineering
    [conference](http://homepages.cs.ncl.ac.uk/brian.randell/NATO/nato1968.PDF)
    (1968), in "4.3.3. FEEDBACK THROUGH MONITORING AND SIMULATION" (p. 31 in the
    PDF):

    Alan Perlis says:

    >  "I'd like to read three sentences to close this issue.
    >  
    >    1. A software system can best be designed if the testing is interlaced with
    >       the designing instead of being used after the design.
    >  
    >    2. A simulation which matches the requirements contains the control which
    >       organizes the design of the system.
    >  
    >    3. Through successive repetitions of this process of interlaced testing and
    >       design the model ultimately becomes the software system itself. I think
    >       that it is the key of the approach that has been suggested, that there is
    >       no such question as testing things after the fact with simulation models,
    >       but that in effect the testing and the replacement of simulations with
    >       modules that are deeper and more detailed goes on with the simulation
    >       model controlling, as it were, the place and order in which these things
    >       are done."
