# Opus

Starknet contracts of [Opus](https://opus.money).

## Local dev

### Prerequisites

To run Opus locally, you'll need to install [starknet-devnet-rs](https://github.com/0xSpaceShard/starknet-devnet-rs). If you already have the tools installed, please ensure you are running the most up-to-date versions. Next, you need to install [Scarb](https://docs.swmansion.com/scarb/docs.html) to compile the Cairo smart contracts. We recommend [installing via `asdf`](https://docs.swmansion.com/scarb/download.html#install-via-asdf). Finally, you need to install [Starknet Foundry](https://github.com/foundry-rs/starknet-foundry).

### Setup

In one shell, run `scarb run devnet` to boot up a Devnet instance. You can use the `http://localhost:5050` as the RPC address.

In another shell, from the `scripts` directory, run `scarb run deploy_devnet`. That will compile and deploy the contracts on the local Devnet and do the initial required setup.

Note that Devnet deployments are ephemeral. Once you kill your Devnet instance, the state is lost. After restarting, you will have to deploy the contracts again, using the script mentioned above.

### Addresses

#### Sepolia

| Module | Address |
| ------ | --------|
| Abbot       | `0x55753ea07d7c53b0d512dd14aa1fb536b02efc179907905610619eecaac1e97` |
| Absorber    | `0x32e5f6bfc937e239e9f1c7c2c30f0d8ce59d7d703d82bc69382b4d2b0be1e4e` |
| Allocator   | `0x470ad58d601501eab46479e69c0d9367e2b429aca88a1775114e3b074b2117b` |
| Caretaker   | `0x1461305951ac7fb7af835a9a19b99ae5e135ba1fb64477d4b92a871fb85a2b1` |
| Controller  | `0x5c4d4b9ce7f54dc50354b99dfca29c3ba3935501e5244e048fa87b83043ddc2` |
| Equalizer   | `0x54b46ed341533fe4da0116f27e201276165e3a3fd030ac391b6e9967668996d` |
| Flash Mint  | `0x6f1577c508f95e633d22eaa65c5781442651336d30a95ba149a80fd85db29bc` |
| Frontend Data Provider | `0x6f7cf629552047a337324712571068b3f8f2deddcc0454533596ef5dfa192d` |
| Gate[ETH]   | `0x23dbc80de342f86f2b33b27d5593c259809961d9ecbd9f69b7088babba1016f` |
| Gate[STRK]  | `0x2918116ed1154cfe378eaefa5ee83914c9bed787815cdb5a82d25185737dad` |
| Pragma      | `0xa163eb702f1cba67680cb67a2ad018dd6d349b76ebc9d85102a83857948304` |
| Purger      | `0x1e188c4223245660e692e7f0b9834d11687cec5aa37da0889cbe2e2e2743c28` |
| Seer        | `0x1ba77782ba5dea67bcf4f71c2b98849b598d030df02952bf8f62e3eb6b5b192` |
| Sentinel    | `0x255e43013fd414520d27a0491c64aa03705e6f728999d0ceb44e395ac5c9c1d` |
| Shrine      | `0x7d2a06078ee45540e9507a0daf01ac94f0550b675958dda88cbbc6fc8993708` |
