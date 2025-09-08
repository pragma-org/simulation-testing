---
author: Stevan A
date: 2025-09-08
status: sketch
---

# Optimisation: running simulations in parallel

*Work in progress, please don't share, but do feel free to get involved!*

We've seen how to run a single simulation of a distributed system, in this post
we'll discuss how to parallelise the simulations to better use our hardware and
cover more ground faster.

## Motivation

Given the combinatorial explosion of the state space, which especially faults
introduce, we want our exploration to be as parallel as possible.

## Possibilities to explore

One thing we want to avoid is to run simulations with the same seed on two
different CPUs/cores, one way around this is to use a [counter-based random
number
generator](https://en.wikipedia.org/wiki/Counter-based_random_number_generator)
(for example [Philox](https://dl.acm.org/doi/10.1145/2063384.2063405) or
[Squares](https://arxiv.org/abs/2004.06278)).

Another option might be to somehow hash the generated test cases, and have the
CPUs/cores check if it has already been run. The (semantic) version of the SUT
should probably be in that hash, so that things get retested if the SUT
changes. It might be the case that if the test cases are sufficiently random or
long, we'll rarely generate the same test twice. This is something that would
need to be measured. On the other hand it might make sense to try to enumerate
all test cases upto some length.
