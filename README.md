# Opus

Starknet contracts of [Opus](https://opus.money).

## Local dev

### Prerequisites

To run Opus locally, you'll need to install [Katana (part of Dojo)](https://www.dojoengine.org/en/) and [starkli](https://github.com/xJonathanLEI/starkli). If you already have the tools installed, please ensure you are running the most up-to-date versions. You also need to have `zsh` available on your system (not necessarily as your primary shell). Finally, you need to install [Scarb](https://docs.swmansion.com/scarb/docs.html) to compile the Cairo smart contracts. We recommend [installing via `asdf`](https://docs.swmansion.com/scarb/download.html#install-via-asdf).

### Setup

In one shell, run `scarb run ktn` to boot up a Katana instance. You can use the `http://localhost:5050` as the RPC address.

In another shell, execute `./deployment/deploy_all.sh` script. That will compile and deploy the contracts on the local Katana devnet and do the initial required setup.

Note that Katana deploymnets are ephemeral. Once you kill your Katana instance, the state is lost. After restarting, you will have to deploy the contracts again, using the script mentioned above.
