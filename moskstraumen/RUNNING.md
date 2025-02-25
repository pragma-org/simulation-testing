# Running

## Blackbox test via stdio

### Maelstrom

#### Get the jar

```bash
wget https://github.com/jepsen-io/maelstrom/releases/download/v0.2.4/maelstrom.tar.bz2
tar xf maelstrom.tar.bz2
cd maelstrom
```

#### Install run-time dependencies

##### Nix

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

##### Without Nix

See the following
[instructions](https://github.com/jepsen-io/maelstrom/blob/main/doc/01-getting-ready/index.md#prerequisites).

#### Running the tests with provided echo demo

```bash
./maelstrom test -w echo --bin demo/ruby/echo.rb --time-limit 5 --log-stderr --rate 10 --nodes n1
```

### Compile our version of echo

```
git clone https://github.com/pragma-org/simulation-testing.git
cd simulation-testing/moskstraumen
cabal build
export OUR_ECHO_BINARY=$(cabal list-bin echo)
```

### Test our version of echo using Maelstrom

```bash
cd $MAELSTROM_DIRECTORY # Change as appropriate
time ./maelstrom test -w echo --bin $OUR_ECHO_BINARY --time-limit 5 --log-stderr --rate 10 --nodes n1
[...]
Everything looks good! ヽ(‘ー`)ノ

real    0m11.671s
user    0m12.301s
sys     0m0.565s
```

### Blackbox test our echo with Moskstraumen

The same binary that we Maelstrom tested can also be blackbox tested via
stdio using Moskstraumen as follows:

```bash
cd $MOSKSTRAUMEN_DIRECTORY
cabal repl
```

```
> import Moskstraumen.Example.Echo
> :set +s
> unit_blackboxTestEcho
[...]
(0.38 secs, 7,995,552 bytes)
```

Do node that these tests are currently not as elaborate as the Maelstrom
ones (no fault-injection in particular). Unlike in the Maelstrom case,
these tests are deterministic.

## Simulation test our echo example with Moskstraumen

If the SUT is written in the same language as Moskstraumen (Haskell
currently, but can hopefully easily be ported to other languages), we
can also avoid the overhead of passing messages via stdio as follows:

```
unit_simulationTestEcho
[...]
(0.04 secs, 8,233,240 bytes)
```
