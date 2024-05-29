# Opus

Starknet contracts of [Opus](https://opus.money).

## Local dev

### Prerequisites

To run Opus locally, you'll need to install [starknet-devnet-rs](https://github.com/0xSpaceShard/starknet-devnet-rs). If you already have the tools installed, please ensure you are running the most up-to-date versions. Next, you need to install [Scarb](https://docs.swmansion.com/scarb/docs.html) to compile the Cairo smart contracts. We recommend [installing via `asdf`](https://docs.swmansion.com/scarb/download.html#install-via-asdf). Finally, you need to install [Starknet Foundry](https://github.com/foundry-rs/starknet-foundry).

### Setup

In one shell, run `scarb run load_devnet` to boot up a Devnet instance with the initial deployment and setup of contracts based on the `devnet_dump.json` state file. The RPC address of this Devnet instance is `http://localhost:5050`.

To start a clean Devnet instance, run `scarb run restart_devnet`. In another shell, from the `scripts` directory, run `scarb run deploy_devnet -p deployment`. That will compile and deploy the contracts on the local Devnet and do the initial required setup.

Once you kill your Devnet instance, the state is lost unless the latest `devnet_dump.json` state file is committed. 

### Addresses

#### Sepolia

| Module | Address |
| ------ | --------|
| Abbot       | `0x04280b97ecb8f1e0536e41888e387a04c3796e393f7086e5e24d61614927bc30` |
| Absorber    | `0x05cf86333b32580be7a73c8150f2176047bab151df7506b6e30217594798fab5` |
| Allocator   | `0x00dd24daea0f6cf5ee0a206e6a27c4d5b66a978f19e3a4877de23ab5a76f905d` |
| Caretaker   | `0x004eb68cdc4009f0a7af80ecb34b91822649b139713e7e9eb9b11b10ee47aada` |
| Controller  | `0x0005efaa9df09e86be5aa8ffa453adc11977628ddc0cb493625ca0f3caaa94b2` |
| Equalizer   | `0x013be5f3de034ca1a0dec2b2da4cce2d0fe5505511cbea7a309979c45202d052` |
| Flash Mint  | `0x0726e7d7bef2bcfc2814e0d5f0735b1a9326a98f2307a5edfda8db82d60d3f5f` |
| Frontend Data Provider | `0x03d124e4166a09fb92787d480d44d6c25e6f638f706f8ae4074ee2766b634293` |
| Gate[ETH]   | `0x02e1e0988565d99cd3a384e9f9cf2d348af50ee1ad549880aa37ba625e8c98d6` |
| Gate[STRK]  | `0x05c6ec6e1748fbab3d65c2aa7897aeb7d7ec843331c1a469666e162da735fd5f` |
| Pragma      | `0x02a67fac89d6921b05067b99e2491ce753778958ec89b0b0221b22c16a3073f7` |
| Purger      | `0x0397fda455fd16d76995da81908931057594527b46cc99e12b8e579a9127e372` |
| Seer        | `0x07bdece1aeb7f2c31a90a6cc73dfdba1cb9055197cca24b6117c9e0895a1832d` |
| Sentinel    | `0x04c4d997f2a4b1fbf9db9c290ea1c97cb596e7765e058978b25683efd88e586d` |
| Shrine      | `0x0398c179d65929f3652b6b82875eaf5826ea1c9a9dd49271e0d749328186713e` |
