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

#### Mainnet

| Module | Address |
| ------ | --------|
| Abbot       | `0x04d0bb0a4c40012384e7c419e6eb3c637b28e8363fb66958b60d90505b9c072f` |
| Absorber    | `0x000a5e1c1ffe1384b30a464a61b1af631e774ec52c0e7841b9b5f02c6a729bc0` |
| Allocator   | `0x06a3593f7115f8f5e0728995d8924229cb1c4109ea477655bad281b36a760f41` |
| Caretaker   | `0x012a5efcb820803ba700503329567fcdddd7731e0d05e06217ed1152f956dbb0` |
| Controller  | `0x07558a9da2fac57f5a4381fef8c36c92ca66adc20978063982382846f72a4448` |
| Equalizer   | `0x066e3e2ea2095b2a0424b9a2272e4058f30332df5ff226518d19c20d3ab8e842` |
| Flash Mint  | `0x05e57a033bb3a03e8ac919cbb4e826faf8f3d6a58e76ff7a13854ffc78264681` |
| Frontend Data Provider | `0x037063d98568c6d9b383f5353b2f85d9710c0338ef8c49c15700e68d046da430` |
| Gate[ETH]   | `0x0315ce9c5d3e5772481181441369d8eea74303b9710a6c72e3fcbbdb83c0dab1` |
| Gate[STRK]  | `0x031a96fe18fe3fdab28822c82c81471f1802800723c8f3e209f1d9da53bc637d` |
| Gate[WBTC]  | `0x05bc1c8a78667fac3bf9617903dbf2c1bfe3937e1d37ada3d8b86bf70fb7926e` |
| Gate[WSTETH] | `0x02d1e95661e7726022071c06a95cdae092595954096c373cde24a34bb3984cbf` |
| Gate[xSTRK] | `0x04a3e7dffd8e74a706be9abe6474e07fbbcf41e1be71387514c4977d54dbc428` |
| Gate[sSTRK] | `0x03b709f3ab9bc072a195b907fb2c27688723b6e4abb812a8941def819f929bd8` |
| Pragma      | `0x0734abeebd842926c860f3f82d23a7d2e0a24c8756d7f6b88a7456dc95a7e0fd` |
| Purger      | `0x0149c1539f39945ce1f63917ff6076845888ab40e9327640cb78dcaebfed42e4` |
| Receptor    | `0x059c159d9a87a34f17c4991e81b0d937aaf86a29f682ce0951536265bd6a1678` |
| Seer        | `0x07b4d65be7415812cea9edcfce5cf169217f4a53fce84e693fe8efb5be9f0437` |
| Sentinel    | `0x06428ec3221f369792df13e7d59580902f1bfabd56a81d30224f4f282ba380cd` |
| Shrine      | `0x0498edfaf50ca5855666a700c25dd629d577eb9afccdf3b5977aec79aee55ada` |
| Transmuter[USDC] (Restricted) | `0x03878595db449e1af7de4fb0c99ddb01cac5f23f9eb921254f4b0723a64a23cb` |


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
| Frontend Data Provider | `0x0148763033b7ecb24f425e150867835c95ac40dfd7bc8b1ff26dd4c3fed59fce` |
| Gate[ETH]   | `0x02e1e0988565d99cd3a384e9f9cf2d348af50ee1ad549880aa37ba625e8c98d6` |
| Gate[STRK]  | `0x05c6ec6e1748fbab3d65c2aa7897aeb7d7ec843331c1a469666e162da735fd5f` |
| Pragma v2   | `0x077402727ec67d177e10b2a4e54b631d5d1bad6dc0dda08cd15c7f179aede624` |
| Purger      | `0x02ffd8c21cbfb3f5efb78f250f0c8e4e527cbb264e2d6e8f2731cb594d2ed81c` |
| Seer v2     | `0x044501c24bb9c4eb1b02372943d42320d091826e7b047c23132b427a2b8b7696` |
| Sentinel    | `0x04c4d997f2a4b1fbf9db9c290ea1c97cb596e7765e058978b25683efd88e586d` |
| Shrine      | `0x0398c179d65929f3652b6b82875eaf5826ea1c9a9dd49271e0d749328186713e` |
| Transmuter[USDC] (Restricted) | `0x03280ae1d855fd195a63bc72fa19c2f8a9820b7871f34eff13e3841ff7388c81` |