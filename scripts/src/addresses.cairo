use starknet::{ClassHash, ContractAddress};

// https://github.com/starknet-io/starknet-addresses/blob/master/bridged_tokens/

pub fn eth_addr() -> ContractAddress {
    0x49D36570D4E46F48E99674BD3FCC84644DDD6B96F7C741B1562B82F9E004DC7.try_into().expect('invalid ETH address')
}

pub fn strk_addr() -> ContractAddress {
    0x04718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d.try_into().expect('invalid STRK address')
}

pub fn frontend_data_provider_class_hash() -> ClassHash {
    0x057de79aa98ec372b03eae8a68077e719926035da35ac6ab0d64822d41457019.try_into().expect('invalid fdp class hash')
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
        0x03280ae1d855fd195a63bc72fa19c2f8a9820b7871f34eff13e3841ff7388c81.try_into().unwrap()
    }
}

pub mod mainnet {
    use starknet::ContractAddress;

    pub fn admin() -> ContractAddress {
        0x0684f8b5dd37cad41327891262cb17397fdb3daf54e861ec90f781c004972b15.try_into().expect('invalid admin address')
    }

    pub fn multisig() -> ContractAddress {
        0x00Ca40fCa4208A0c2a38fc81a66C171623aAC3B913A4365F7f0BC0EB3296573C.try_into().expect('invalid multisig address')
    }

    // Tokens
    //
    // Unless otherwise stated, token's address is available at:
    // https://github.com/starknet-io/starknet-addresses/blob/master/bridged_tokens/mainnet.json

    pub fn dai() -> ContractAddress {
        0x05574eb6b8789a91466f902c380d978e472db68170ff82a5b650b95a58ddf4ad.try_into().expect('invalid DAI address')
    }

    pub fn usdc() -> ContractAddress {
        0x053c91253bc9682c04929ca02ed00b3e423f6710d2ee7e0d5ebb06f3ecf368a8.try_into().expect('invalid USDC address')
    }

    pub fn usdt() -> ContractAddress {
        0x068f5c6a61780768455de69077e07e89787839bf8166decfbf92b645209c0fb8.try_into().expect('invalid USDC address')
    }

    pub fn wbtc() -> ContractAddress {
        0x03fe2b97c1fd336e750087d68b9b867997fd64a2661ff3ca5a7c771641e8e7ac.try_into().expect('invalid WBTC address')
    }

    pub fn wsteth() -> ContractAddress {
        0x042b8f0484674ca266ac5d08e4ac6a3fe65bd3129795def2dca5c34ecc5f96d2.try_into().expect('invalid WSTETH address')
    }

    pub fn wsteth_canonical() -> ContractAddress {
        0x0057912720381af14b0e5c87aa4718ed5e527eab60b3801ebf702ab09139e38b.try_into().expect('invalid WSTETH address')
    }

    pub fn xstrk() -> ContractAddress {
        0x028d709c875c0ceac3dce7065bec5328186dc89fe254527084d1689910954b0a.try_into().expect('invalid xSTRK address')
    }

    pub fn sstrk() -> ContractAddress {
        0x0356f304b154d29d2a8fe22f1cb9107a9b564a733cf6b4cc47fd121ac1af90c9.try_into().expect('invalid sSTRK address')
    }

    // External

    // https://docs.ekubo.org/integration-guides/reference/contract-addresses
    pub fn ekubo_oracle_extension() -> ContractAddress {
        0x005e470ff654d834983a46b8f29dfa99963d5044b993cb7b9c92243a69dab38f
            .try_into()
            .expect('invalid ekubo oracle addr')
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

    // deployments
    pub fn abbot() -> ContractAddress {
        0x04d0bb0a4c40012384e7c419e6eb3c637b28e8363fb66958b60d90505b9c072f.try_into().unwrap()
    }

    pub fn absorber() -> ContractAddress {
        0x000a5e1c1ffe1384b30a464a61b1af631e774ec52c0e7841b9b5f02c6a729bc0.try_into().unwrap()
    }

    pub fn allocator() -> ContractAddress {
        0x06a3593f7115f8f5e0728995d8924229cb1c4109ea477655bad281b36a760f41.try_into().unwrap()
    }

    pub fn caretaker() -> ContractAddress {
        0x012a5efcb820803ba700503329567fcdddd7731e0d05e06217ed1152f956dbb0.try_into().unwrap()
    }

    pub fn controller() -> ContractAddress {
        0x07558a9da2fac57f5a4381fef8c36c92ca66adc20978063982382846f72a4448.try_into().unwrap()
    }

    pub fn ekubo() -> ContractAddress {
        0x048a1cc699025faec330b85ab74a7586e424206a481daed14160982b57567cce.try_into().unwrap()
    }

    pub fn equalizer() -> ContractAddress {
        0x066e3e2ea2095b2a0424b9a2272e4058f30332df5ff226518d19c20d3ab8e842.try_into().unwrap()
    }

    pub fn eth_gate() -> ContractAddress {
        0x0315ce9c5d3e5772481181441369d8eea74303b9710a6c72e3fcbbdb83c0dab1.try_into().unwrap()
    }

    pub fn flash_mint() -> ContractAddress {
        0x05e57a033bb3a03e8ac919cbb4e826faf8f3d6a58e76ff7a13854ffc78264681.try_into().unwrap()
    }

    pub fn frontend_data_provider() -> ContractAddress {
        0x023037703b187f6ff23b883624a0a9f266c9d44671e762048c70100c2f128ab9.try_into().unwrap()
    }

    pub fn pragma() -> ContractAddress {
        0x0532f8b442e90eae93493a4f3e4f6d3bf2579e56a75238b786a5e90cb82fdfe9.try_into().unwrap()
    }

    pub fn purger() -> ContractAddress {
        0x02cef5286b554f4122a2070bbd492a95ad810774903c92633979ed54d51b04ca.try_into().unwrap()
    }

    pub fn receptor() -> ContractAddress {
        0x059c159d9a87a34f17c4991e81b0d937aaf86a29f682ce0951536265bd6a1678.try_into().unwrap()
    }

    pub fn seer() -> ContractAddress {
        0x076baf9a48986ae11b144481aec7699823d7ebc5843f30cf47b053ebfe579824.try_into().unwrap()
    }

    pub fn sentinel() -> ContractAddress {
        0x06428ec3221f369792df13e7d59580902f1bfabd56a81d30224f4f282ba380cd.try_into().unwrap()
    }

    pub fn shrine() -> ContractAddress {
        0x0498edfaf50ca5855666a700c25dd629d577eb9afccdf3b5977aec79aee55ada.try_into().unwrap()
    }

    pub fn sstrk_gate() -> ContractAddress {
        0x03b709f3ab9bc072a195b907fb2c27688723b6e4abb812a8941def819f929bd8.try_into().unwrap()
    }

    pub fn strk_gate() -> ContractAddress {
        0x031a96fe18fe3fdab28822c82c81471f1802800723c8f3e209f1d9da53bc637d.try_into().unwrap()
    }

    pub fn usdc_transmuter_restricted() -> ContractAddress {
        0x03878595db449e1af7de4fb0c99ddb01cac5f23f9eb921254f4b0723a64a23cb.try_into().unwrap()
    }

    pub fn wbtc_gate() -> ContractAddress {
        0x05bc1c8a78667fac3bf9617903dbf2c1bfe3937e1d37ada3d8b86bf70fb7926e.try_into().unwrap()
    }

    pub fn wsteth_gate() -> ContractAddress {
        0x02d1e95661e7726022071c06a95cdae092595954096c373cde24a34bb3984cbf.try_into().unwrap()
    }

    pub fn xstrk_gate() -> ContractAddress {
        0x028d709c875c0ceac3dce7065bec5328186dc89fe254527084d1689910954b0a.try_into().unwrap()
    }
}
