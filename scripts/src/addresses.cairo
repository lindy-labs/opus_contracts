use starknet::ContractAddress;

// https://github.com/starknet-io/starknet-addresses/blob/master/bridged_tokens/

pub fn eth_addr() -> ContractAddress {
    0x49D36570D4E46F48E99674BD3FCC84644DDD6B96F7C741B1562B82F9E004DC7.try_into().expect('invalid ETH address')
}

pub fn strk_addr() -> ContractAddress {
    0x04718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d.try_into().expect('invalid STRK address')
}

pub fn wbtc_addr() -> ContractAddress {
    // only on mainnet
    0x03fe2b97c1fd336e750087d68b9b867997fd64a2661ff3ca5a7c771641e8e7ac.try_into().expect('invalid WBTC address')
}

pub fn wsteth_addr() -> ContractAddress {
    // only on mainnet
    0x042b8f0484674ca266ac5d08e4ac6a3fe65bd3129795def2dca5c34ecc5f96d2.try_into().expect('invalid wstETH address')
}

pub mod devnet {
    use starknet::ContractAddress;

    // devnet_admin.json
    pub fn admin() -> ContractAddress {
        0x42044b3252fcdaeccfc2514c2b72107aed76855f7251469e2f105d97ec6b6e5.try_into().expect('invalid admin address')
    }

    // these deployments are based on replaying the transactions in `scripts/devnet_dump.json` and should not be used 
    // in the deployment package
    pub fn abbot() -> ContractAddress {
        0x2f8940f748fee76656e25627fb9fc9237cf76827eb94f1cb8ed6db00e57491e.try_into().unwrap()
    }

    pub fn absorber() -> ContractAddress {
        0x6ad5948495fb2b102c72035770371a6370414ac845ae678c55a256d5cc87d76.try_into().unwrap()
    }

    pub fn allocator() -> ContractAddress {
        0x281e7062aa4ee1d58eb9692ec0a1737852c98b6466c7787b5c24ab98c15a640.try_into().unwrap()
    }

    pub fn caretaker() -> ContractAddress {
        0x5dfcded9b418bab8774ae07ea6a04a4f462f4db23c574472e4ea68ecdbb30be.try_into().unwrap()
    }

    pub fn controller() -> ContractAddress {
        0x66d29efb9936beef9192a010027788254c9c3329d551e274dd17002c425a07.try_into().unwrap()
    }

    pub fn equalizer() -> ContractAddress {
        0x1e53d5b14a7d9d7b8bd90707e4b7e7ccb2aae85f823e5bed449e807488f7684.try_into().unwrap()
    }

    pub fn eth_gate() -> ContractAddress {
        0x7ce8dbfcf1625a285ab2263bbef126d347547263bd897078732080101a7a3eb.try_into().unwrap()
    }

    pub fn flash_mint() -> ContractAddress {
        0x5a1f1bc3b5eac6b514ddaf085ca9a668f5c1511bf265b9aa65cdc32791a405b.try_into().unwrap()
    }

    pub fn frontend_data_provider() -> ContractAddress {
        0x397c140f6eded24bbad9b8ac00920fd12e33e8c6f7cc40ca16fbd5ebf993c5b.try_into().unwrap()
    }

    pub fn mock_pragma() -> ContractAddress {
        0x5275fc46b59af9a110b087b2129ccdfd996677d6ce4aaba2f0bcd7561bfa2fc.try_into().unwrap()
    }

    pub fn mock_switchboard() -> ContractAddress {
        0x6bcfe770eca653c2940f51537885e88e3499e04ab2df82e58ec6bc8a8d4325d.try_into().unwrap()
    }

    pub fn pragma() -> ContractAddress {
        0x267595a58145771b39b66feb57bf50fd9321506d12a39ebace38c4995a3b77a.try_into().unwrap()
    }

    pub fn purger() -> ContractAddress {
        0x707c16dc18135483948fcb68e963a3c68cdbeeeef1e2bfe679ce032ad306403.try_into().unwrap()
    }

    pub fn seer() -> ContractAddress {
        0x428adfdb17ceb3d7a6cc8898e14c5f035a92b1db5ed0a11d6339122a57e5b40.try_into().unwrap()
    }

    pub fn sentinel() -> ContractAddress {
        0x75b3bb3a8c234a01b0b10f29fcb32f28b6d2ccf13b0e741ee8c77d902415b36.try_into().unwrap()
    }

    pub fn shrine() -> ContractAddress {
        0x6a3ca8d0d0a0a022c78fc03dc19783f9b75b51d1629e678ad14154abcef67a.try_into().unwrap()
    }

    pub fn strk_gate() -> ContractAddress {
        0xe5ac1bcb276ab1e46b1e647f030b7e3e8624038dd4d61bbdc010ba3de58925.try_into().unwrap()
    }

    pub fn switchboard() -> ContractAddress {
        0x6a2f82103368f594915e49baed4a345b6371c053583b7a77512e24e955ac83f.try_into().unwrap()
    }

    pub fn wbtc() -> ContractAddress {
        0x6d092cf0cf10d761e1e615cf1c0249299742175097ba3a6da62f69d532af813.try_into().unwrap()
    }

    pub fn wbtc_gate() -> ContractAddress {
        0x1aad2d6cc4356359fc88784228d73442488a79bd8af97b2ed83aa866bda6219.try_into().unwrap()
    }
}

pub mod sepolia {
    use starknet::ContractAddress;

    pub fn admin() -> ContractAddress {
        0x17721cd89df40d33907b70b42be2a524abeea23a572cf41c79ffe2422e7814e.try_into().expect('invalid admin address')
    }

    // https://github.com/Astraly-Labs/pragma-oracle?tab=readme-ov-file#deployment-addresses
    pub fn pragma_spot_oracle() -> ContractAddress {
        0x36031daa264c24520b11d93af622c848b2499b66b41d611bac95e13cfca131a
            .try_into()
            .expect('invalid pragma spot address')
    }

    pub fn pragma_twap_oracle() -> ContractAddress {
        0x54563a0537b3ae0ba91032d674a6d468f30a59dc4deb8f0dce4e642b94be15c
            .try_into()
            .expect('invalid pragma twap address')
    }

    // deployments
    pub fn abbot() -> ContractAddress {
        0x04280b97ecb8f1e0536e41888e387a04c3796e393f7086e5e24d61614927bc30.try_into().unwrap()
    }

    pub fn absorber() -> ContractAddress {
        0x05cf86333b32580be7a73c8150f2176047bab151df7506b6e30217594798fab5.try_into().unwrap()
    }

    pub fn allocator() -> ContractAddress {
        0x00dd24daea0f6cf5ee0a206e6a27c4d5b66a978f19e3a4877de23ab5a76f905d.try_into().unwrap()
    }

    pub fn caretaker() -> ContractAddress {
        0x004eb68cdc4009f0a7af80ecb34b91822649b139713e7e9eb9b11b10ee47aada.try_into().unwrap()
    }

    pub fn controller() -> ContractAddress {
        0x0005efaa9df09e86be5aa8ffa453adc11977628ddc0cb493625ca0f3caaa94b2.try_into().unwrap()
    }

    pub fn equalizer() -> ContractAddress {
        0x013be5f3de034ca1a0dec2b2da4cce2d0fe5505511cbea7a309979c45202d052.try_into().unwrap()
    }

    pub fn eth_gate() -> ContractAddress {
        0x02e1e0988565d99cd3a384e9f9cf2d348af50ee1ad549880aa37ba625e8c98d6.try_into().unwrap()
    }

    pub fn flash_mint() -> ContractAddress {
        0x0726e7d7bef2bcfc2814e0d5f0735b1a9326a98f2307a5edfda8db82d60d3f5f.try_into().unwrap()
    }

    pub fn frontend_data_provider() -> ContractAddress {
        0x0348d8f672ea7f8f57ae45682571177a4d480301f36af45931bb197c37f6007a.try_into().unwrap()
    }

    pub fn pragma() -> ContractAddress {
        0x02a67fac89d6921b05067b99e2491ce753778958ec89b0b0221b22c16a3073f7.try_into().unwrap()
    }

    pub fn purger() -> ContractAddress {
        0x0397fda455fd16d76995da81908931057594527b46cc99e12b8e579a9127e372.try_into().unwrap()
    }

    pub fn seer() -> ContractAddress {
        0x07bdece1aeb7f2c31a90a6cc73dfdba1cb9055197cca24b6117c9e0895a1832d.try_into().unwrap()
    }

    pub fn sentinel() -> ContractAddress {
        0x04c4d997f2a4b1fbf9db9c290ea1c97cb596e7765e058978b25683efd88e586d.try_into().unwrap()
    }

    pub fn shrine() -> ContractAddress {
        0x0398c179d65929f3652b6b82875eaf5826ea1c9a9dd49271e0d749328186713e.try_into().unwrap()
    }

    pub fn strk_gate() -> ContractAddress {
        0x05c6ec6e1748fbab3d65c2aa7897aeb7d7ec843331c1a469666e162da735fd5f.try_into().unwrap()
    }
}

pub mod mainnet {
    use starknet::ContractAddress;

    pub fn admin() -> ContractAddress {
        0x05ef3d22382af4291903e019c3a947e1ad808d8772303a7a7e564dc8376d466a.try_into().expect('invalid admin address')
    }

    // TODO
    pub fn multisig() -> ContractAddress {
        0x17721cd89df40d33907b70b42be2a524abeea23a572cf41c79ffe2422e7814e.try_into().expect('invalid admin address')
    }

    // https://github.com/Astraly-Labs/pragma-oracle?tab=readme-ov-file#deployment-addresses
    pub fn pragma_spot_oracle() -> ContractAddress {
        0x2a85bd616f912537c50a49a4076db02c00b29b2cdc8a197ce92ed1837fa875b
            .try_into()
            .expect('invalid pragma spot address')
    }

    pub fn pragma_twap_oracle() -> ContractAddress {
        0x49eefafae944d07744d07cc72a5bf14728a6fb463c3eae5bca13552f5d455fd
            .try_into()
            .expect('invalid pragma twap address')
    }
}
