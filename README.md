# Opus

Starknet contracts of [Opus](https://opus.money).

## Local dev

### Prerequisites

To run Opus locally, you'll need to install [starknet-devnet-rs](https://github.com/0xSpaceShard/starknet-devnet-rs). If you already have the tools installed, please ensure you are running the most up-to-date versions. Next, you need to install [Scarb](https://docs.swmansion.com/scarb/docs.html) to compile the Cairo smart contracts. We recommend [installing via `asdf`](https://docs.swmansion.com/scarb/download.html#install-via-asdf). Finally, you need to install [Starknet Foundry](https://github.com/foundry-rs/starknet-foundry).

### Setup

In one shell, run `scarb run devnet` to boot up a Devnet instance. You can use the `http://localhost:5050` as the RPC address.

In another shell, from the `scripts` directory, run `scarb run deploy`. That will compile and deploy the contracts on the local Devnet and do the initial required setup.

Note that Devnet deployments are ephemeral. Once you kill your Devnet instance, the state is lost. After restarting, you will have to deploy the contracts again, using the script mentioned above.
