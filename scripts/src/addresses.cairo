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

pub mod devnet {
    use starknet::ContractAddress;

    // devnet_admin.json
    pub fn admin() -> ContractAddress {
        0x42044b3252fcdaeccfc2514c2b72107aed76855f7251469e2f105d97ec6b6e5.try_into().expect('invalid admin address')
    }

    // these deployments are based on replaying the transactions in `scripts/devnet_dump.json` and should not be used 
    // in the deployment package
    pub fn abbot() -> ContractAddress {
        0x24957207e8e66e8aa79b9ed3ea728656a0a9f1746db5128a591728ba8d23257.try_into().unwrap()
    }

    pub fn absorber() -> ContractAddress {
        0x3f49c8ac257f0ec7762c64a70d4d0517fa70bb0187ab2304248117ff01716ec.try_into().unwrap()
    }

    pub fn allocator() -> ContractAddress {
        0x18fa2a5f5409a6796fbccca89dcadc752fa719ae2914cff36c97d209493b868.try_into().unwrap()
    }

    pub fn caretaker() -> ContractAddress {
        0x4ca7205c4d6151c2194b5bced8a0e6c34455f18a86fa6658b8c3ee916bc975f.try_into().unwrap()
    }

    pub fn controller() -> ContractAddress {
        0xceb53abb5ecac290fc5ddb379a184523f18dafde9a4df876de8943261d708c.try_into().unwrap()
    }

    pub fn equalizer() -> ContractAddress {
        0x31cf8fff930b466755e77006c34da64aa41d494e3eb0761af87a281469deddf.try_into().unwrap()
    }

    pub fn eth_gate() -> ContractAddress {
        0xa1889b408e206392030ee584bd939b4a0de72c9614c22f069da6bb562549cc.try_into().unwrap()
    }

    pub fn flash_mint() -> ContractAddress {
        0x1515b5621019f6bfcb95adbf848345441b59a7becbf3820f6dd67049a73b2a3.try_into().unwrap()
    }

    pub fn frontend_data_provider() -> ContractAddress {
        0x7460f81aadcbddd5db3cc9fb713c2884eecb4dba08796217b335b668cab6625.try_into().unwrap()
    }

    pub fn mock_pragma() -> ContractAddress {
        0x6723b14bcd87ff758ee1bed90beb3c94b02a27ad826bb8ea4b02432f175c474.try_into().unwrap()
    }

    pub fn mock_switchboard() -> ContractAddress {
        0x310e773ea6cc8195d53adbb8b3a1015588d828183d6e0d866049bc06ae91c74.try_into().unwrap()
    }

    pub fn pragma() -> ContractAddress {
        0x64b783719a0e563fd3cc6cab27dd50e73c87ba252bbba6f1b0d4633d9178377.try_into().unwrap()
    }

    pub fn purger() -> ContractAddress {
        0x34e0a9935b6f43df9ad7a3c9a3163d969c8c7cf2b47eb67b15272f302065dfd.try_into().unwrap()
    }

    pub fn seer() -> ContractAddress {
        0x5e529e6d64c87aadaacbe2c1d51d5742ecf431ddc069c0fea1d19c69c778844.try_into().unwrap()
    }

    pub fn sentinel() -> ContractAddress {
        0x4b4553a4bd0a721d638316361738064e98680d189c77f8e9fa3a38f45a5afc2.try_into().unwrap()
    }

    pub fn shrine() -> ContractAddress {
        0x34f5f676c27c4c3374ef3dbeeb93772fb0b958f6243f7084b9aa36d770d8c4b.try_into().unwrap()
    }

    pub fn strk_gate() -> ContractAddress {
        0x6d866137e5a1a2491211fd8fc39d1b1309b2afb85d474a52c57d1c6cca1ab21.try_into().unwrap()
    }

    pub fn switchboard() -> ContractAddress {
        0x4472c93e2481da98c49ec1733d879a2a7305518cafdf738895e2882f15570b6.try_into().unwrap()
    }

    pub fn wbtc() -> ContractAddress {
        0x1da68ae2be2f199c32df6361c1e2a94333922fff8fcd64b16be5f750a3112c8.try_into().unwrap()
    }

    pub fn wbtc_gate() -> ContractAddress {
        0x266a21b2fb5fa8ff2225f2187553742f6feea0ccba98d7f35470916edb0f24a.try_into().unwrap()
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
        0x03d124e4166a09fb92787d480d44d6c25e6f638f706f8ae4074ee2766b634293.try_into().unwrap()
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
