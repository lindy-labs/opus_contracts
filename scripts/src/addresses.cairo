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
        0x7f48497532c4ea819861437b7dde60af8bd32f2922ba8ae77ad1893960892b8.try_into().unwrap()
    }

    pub fn absorber() -> ContractAddress {
        0x1c92473117cfcf8a7b8aba58ac54d422529e694056efa8cf1e68d90ad40c48d.try_into().unwrap()
    }

    pub fn allocator() -> ContractAddress {
        0x1c99f9f01617d470a68db7d3a288ceae738dc182bf422508f6d8bee302d4e24.try_into().unwrap()
    }

    pub fn caretaker() -> ContractAddress {
        0x244ca73c52914e7f7eb18f9cf90644b414490b7d7a5776809e35ce9538aa8a6.try_into().unwrap()
    }

    pub fn controller() -> ContractAddress {
        0x67a242213fbb95d97dd65cf5ddcfb92ae0dc93727b9d962c7b7c0357d92fe5.try_into().unwrap()
    }

    pub fn equalizer() -> ContractAddress {
        0x1649094f1bb16d02bb64cd78bf1ec8a326632b9989ea2462579a681f114418c.try_into().unwrap()
    }

    pub fn eth_gate() -> ContractAddress {
        0x50e48fb57b4abd1895600b969153e21aa99b91a7638750e4922d74821c00ba9.try_into().unwrap()
    }

    pub fn flash_mint() -> ContractAddress {
        0x74f0b5f36428898edcdd7ba249cf94ab53f214153626236c69c4db001a83c36.try_into().unwrap()
    }

    pub fn frontend_data_provider() -> ContractAddress {
        0x42e2e55c94cefb8595deb008c6476cb0c6e8887a1b0d7703f6815e4fb083c8c.try_into().unwrap()
    }

    pub fn mock_pragma() -> ContractAddress {
        0x485f7ce22da86b087fed259bca12f7cf4684a02158048d4a7098c61fce9b09f.try_into().unwrap()
    }

    pub fn mock_switchboard() -> ContractAddress {
        0x446e0de2b6ea68f73c027a3a3c06f13828a67230c719f71144c99bca328a2e2.try_into().unwrap()
    }

    pub fn pragma() -> ContractAddress {
        0x60b9d9307875f8559384570b94339933bd9afa9ab12c7ec170ac4aa37b03ba1.try_into().unwrap()
    }

    pub fn purger() -> ContractAddress {
        0x3854c0538ddcd2b5be0901bee66ccc66e313a9e9e51b2cdca0aa420bfbab7a2.try_into().unwrap()
    }

    pub fn seer() -> ContractAddress {
        0x14c6c354b24b7cb5d1d361162dedcd949955b654c3d471256bbcff1b4a28969.try_into().unwrap()
    }

    pub fn sentinel() -> ContractAddress {
        0x5abec6ca54ca6bffba69b028570faf41bf85b04fc053308465c447162bfb591.try_into().unwrap()
    }

    pub fn shrine() -> ContractAddress {
        0x63f6a3e200e1d7d752773cafe84f34db17681029d306478edc1160d11c08b90.try_into().unwrap()
    }

    pub fn strk_gate() -> ContractAddress {
        0x3beae87c85ae726d33e071c982b4d075586f58660a53e1e80deda56c6fb579.try_into().unwrap()
    }

    pub fn switchboard() -> ContractAddress {
        0x301a2fa543f905409698adb96823e293871befeb8459b14633447d01edd1d06.try_into().unwrap()
    }

    pub fn usdc_transmuter_restricted() -> ContractAddress {
        0x290d5ed29ed3df766ae3b2547447c38fb7e4298e5d12a839dc5573afa3a853d.try_into().unwrap()
    }

    pub fn usdc() -> ContractAddress {
        0x4f528b977e2af95a7fec867842a968244e839599b017c99ba05d4eb4078deeb.try_into().unwrap()
    }

    pub fn wbtc() -> ContractAddress {
        0x1f63635007788374016629b9c8843aff4cd34d2a8adb079793f7808b882866d.try_into().unwrap()
    }

    pub fn wbtc_gate() -> ContractAddress {
        0x4e36e43bfec1bf2f5644c11bfb46241d074385b3af9913cef49de67be52aabb.try_into().unwrap()
    }
}

pub mod sepolia {
    use starknet::ContractAddress;

    pub fn admin() -> ContractAddress {
        0x17721cd89df40d33907b70b42be2a524abeea23a572cf41c79ffe2422e7814e.try_into().expect('invalid admin address')
    }

    pub fn usdc() -> ContractAddress {
        0x053b40a647cedfca6ca84f542a0fe36736031905a9639a7f19a3c1e66bfd5080.try_into().expect('invalid usdc address')
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

    pub fn usdc_transmuter_restricted() -> ContractAddress {
        0x3280ae1d855fd195a63bc72fa19c2f8a9820b7871f34eff13e3841ff7388c81.try_into().unwrap()
    }
}
