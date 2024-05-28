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
| Abbot       | `0x05a097b69be75e365885f344243c6a3fb4365211b1c317be7618f3a053cc20cb` |
| Absorber    | `0x02d8ae43423a20893bc1ede1539c040bea032f49330288b6e057b513c17bc4ec` |
| Allocator   | `0x03d134bc438882a51f55483b25a7a4883729d683f27bca3f002a0095cc2a913d` |
| Caretaker   | `0x07423c57bc6bad36297b71966b9f20df7d035380030fa9e31853881aa7d045f8` |
| Controller  | `0x01e5ade161e8acce42b1e5189c0dacce56bf1071f8e7dd7e820a21a8e680a055` |
| Equalizer   | `0x07c979c9afebd8b6085dedbb67759df2d9f023a86db586955a9b8b1e1e86b0cf` |
| Flash Mint  | `0x06d6a03a1d2e0c8332a28a6df144be4bb63c8948cc90b31fa1fd8401b62d8ca5` |
| Frontend Data Provider | `0x026d62645f9afb9bf1d6b2285bdbf9624cc67c74533f215204589006635e4c88` |
| Gate[ETH]   | `0x034653f27732d4402f81ec67824ba67fe1cd9ab47aefaee1b504285a65522c3d` |
| Gate[STRK]  | `0x00164af10285f1eb49adbdc741df26f4766c7fde1870ccafbce71e4b50d251da` |
| Pragma      | `0x00db796445e4325aee38b9b3e8091a82fd7d6be5e152fd2f66bed3b2ab688078` |
| Purger      | `0x005fdc4824f97fbbdfca1f61ce8a8c303ed57d88f799bf00e7aaae39091612cf` |
| Seer        | `0x042b1f32e25ecd7550c210c4764bb1da102b703415ff1ab24626fe882129d143` |
| Sentinel    | `0x066138521c751f0afd02cd6c9cca1a1b0328fd5515b255f4cdca9e259db6c0dc` |
| Shrine      | `0x04e0a8e930582c94e7bebb68a8d272e4c37e86d29b8748e19042ccdf6b86085b` |
