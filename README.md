# Opus

Starknet contracts of [Opus](https://opus.money).

## Local dev

### Prerequisites

To run Opus locally, you'll need to install [starknet-devnet-rs](https://github.com/0xSpaceShard/starknet-devnet-rs). If you already have the tools installed, please ensure you are running the most up-to-date versions. Next, you need to install [Scarb](https://docs.swmansion.com/scarb/docs.html) to compile the Cairo smart contracts. We recommend [installing via `asdf`](https://docs.swmansion.com/scarb/download.html#install-via-asdf). Finally, you need to install [Starknet Foundry](https://github.com/foundry-rs/starknet-foundry).

### Setup

In one shell, run `scarb run devnet` to boot up a Devnet instance. You can use the `http://localhost:5050` as the RPC address.

In another shell, from the `scripts` directory, run `scarb run deploy`. That will compile and deploy the contracts on the local Devnet and do the initial required setup.

Note that Devnet deployments are ephemeral. Once you kill your Devnet instance, the state is lost. After restarting, you will have to deploy the contracts again, using the script mentioned above.

### Addresses

#### Sepolia

| Module | Address |
| ------ | --------|
| Abbot | `0x6352de997a7fde3bc733675180e843b5fe585b7ef464a2987a76fae454af78d` |
| Absorber | `0x48deaee30965a88184619f8b3b30b805727654468ae9b42b483a84831b9e5ea` |
| Allocator | `0xa7b142b8937cb31507fe598252d44a516f2bc64eb285f1807163461d6c208e` |
| Caretaker | `0xeab066a1083f32ff92e3ac9696dc847928fa0f4035bda93dacc34df1cef604` |
| Controller | `0x3297c2080d6c565055ca1c7695b9b6e458600515ebd76101ec4221bcea877ce` |
| Equalizer | `0x43d5cd32847304e168fca09feef5620aaf7c3a0e6fa1689416541be95d8d183` |
| Flash Mint | `0x2c6c7acedfbb6607ecc33cd6b2134f3dea2f16998b44219067063ae4ccb6e42` |
| Gate[ETH] | `0x20ee25588aa6225c58a55110fc5f5b983d074d4ed5b1d98788825a9d3305ac0` |
| Gate[STRK] | `0x594f653061a2181514fad04dc005f7eb8210786a45b577f416029e0ffb01cd7` |
| Pragma | `0x71415935245134eaa125de2df12772443726d5a149a4995f60208c28653a54f` |
| Purger | `0x67f57eec3ce8ba9781985cafcb774283d6450662906691b65d882e13dc59934` |
| Seer | `0x14dac867b21b5b6645cc046e0125cca8e81e8dd9d95ca5dd8e756fa053a2984` |
| Sentinel | `0x2f1778912ef186e2434dfe0957e00ed2122dd48f3aa2e8bc46173fd67bdd065` |
| Shrine | `0x4b3bfe81472b5a01dc3c1fba3456bb0979852deaca43da49d406189371d09e6` |
