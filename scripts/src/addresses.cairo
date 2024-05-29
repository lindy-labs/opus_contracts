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
        0x35e493910af6c1f19fb4e93a5a0f7b216a94ce500bad5ac1d4a3b030a534d52.try_into().unwrap()
    }

    pub fn absorber() -> ContractAddress {
        0x2d9fd7ee306bc387e22f3c38d9584f5ad134284f99f917a557454e50f72ca48.try_into().unwrap()
    }

    pub fn allocator() -> ContractAddress {
        0x28e45d85345a4664c8dbc783ffd8950aae653b135e50e7a983c438f78ef2fd6.try_into().unwrap()
    }

    pub fn caretaker() -> ContractAddress {
        0x15a8105bce92aa7b57896d29527f2206d649f0dd1135d0fcbc1ffb0973f2792.try_into().unwrap()
    }

    pub fn controller() -> ContractAddress {
        0x442e4b7d97e60612412147a5f1db9ae79da022b5fb4420f21da85cb1d858712.try_into().unwrap()
    }

    pub fn equalizer() -> ContractAddress {
        0x77764d1aef5135740b921f7c5894c26e87279ebbc6c55354b15ea177b813a00.try_into().unwrap()
    }

    pub fn eth_gate() -> ContractAddress {
        0x5c3aba3cf90610605f497ddf53da85e48424c1972753a31f2a4988b9e54956f.try_into().unwrap()
    }

    pub fn flash_mint() -> ContractAddress {
        0xde7443a45b5541c9a3794f85727136cae0cab9bac77894b27982d0510202e7.try_into().unwrap()
    }

    pub fn frontend_data_provider() -> ContractAddress {
        0x59c36f7d6b60d549f7b3d98a847225ac87268c61ba519e04a8eb8d2edd16602.try_into().unwrap()
    }

    pub fn mock_pragma() -> ContractAddress {
        0x2e17097c8241e04d350899aab12078f70fced59b90fe00ffc512c021e93067a.try_into().unwrap()
    }

    pub fn mock_switchboard() -> ContractAddress {
        0x74d5c80c714c5b9baa15f4862f3ca989d2f46614d6d01a6e272533010f9981c.try_into().unwrap()
    }

    pub fn pragma() -> ContractAddress {
        0x6286bc2559e454cb18f3864bc8d222ede1e3ed172ec395387575819b690c165.try_into().unwrap()
    }

    pub fn purger() -> ContractAddress {
        0x5b19f7799753fd1a00550186cd226d5bfee37524c331d0c6944ba49e8a14261.try_into().unwrap()
    }

    pub fn seer() -> ContractAddress {
        0x70e746130ea1965e78e8ac214571580d661e4d4fc22d2e1ae7be018ea45a2c3.try_into().unwrap()
    }

    pub fn sentinel() -> ContractAddress {
        0x586333ae3c4bfb73c377697822837849bdaa280734e2ea05b654e5ff5ad3a42.try_into().unwrap()
    }

    pub fn shrine() -> ContractAddress {
        0x2ba3ab88304cb7990c38c69d021d7c61bef9b5934e8ee240689f7976cf7d729.try_into().unwrap()
    }

    pub fn strk_gate() -> ContractAddress {
        0x33fba20bd841967b6a1a9f456ea028cc385ab52f638136dc7d4032c14118a9c.try_into().unwrap()
    }

    pub fn switchboard() -> ContractAddress {
        0x21ca98d6b54f10dad6e3149b0db9222cfacf57762ff56117c85e33cbf2b87a2.try_into().unwrap()
    }

    pub fn wbtc() -> ContractAddress {
        0x186e2d191235b8411d2bb9e18e8d5fca6059662e2c7077571281b5097081df.try_into().unwrap()
    }

    pub fn wbtc_gate() -> ContractAddress {
        0x7112dc7b7766b957f5aa87d585d0cdcc3a8ba075634187863c4db33c0cacd0b.try_into().unwrap()
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
