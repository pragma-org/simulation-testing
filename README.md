# Simulation testing

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

##### Without nix

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

cd $MAELSTROM_DIRECTORY # Change as appropriate
./maelstrom test -w echo --bin $OUR_ECHO_BINARY --time-limit 5 --log-stderr --rate 10 --nodes n1
```
