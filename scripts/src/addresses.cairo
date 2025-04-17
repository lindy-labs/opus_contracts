use starknet::{ClassHash, ContractAddress};

// https://github.com/starknet-io/starknet-addresses/blob/master/bridged_tokens/

pub const ETH: ContractAddress = 0x49D36570D4E46F48E99674BD3FCC84644DDD6B96F7C741B1562B82F9E004DC7.try_into().unwrap();
pub const STRK: ContractAddress = 0x04718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d
    .try_into()
    .unwrap();
pub const FRONTEND_DATA_PROVIDER_CLASS_HASH: ClassHash =
    0x057de79aa98ec372b03eae8a68077e719926035da35ac6ab0d64822d41457019
    .try_into()
    .unwrap();

pub mod devnet {
    use starknet::ContractAddress;

    // devnet_admin.json
    pub const ADMIN: ContractAddress = 0x42044b3252fcdaeccfc2514c2b72107aed76855f7251469e2f105d97ec6b6e5
        .try_into()
        .unwrap();

    // these deployments are based on replaying the transactions in `scripts/devnet_dump.json` and should not be used
    // in the deployment package
    pub const ABBOT: ContractAddress = 0x676c823dfff94667e930b0556c9762bc9b210dffb7248e9f5cc00c411bfd511
        .try_into()
        .unwrap();
    pub const ABSORBER: ContractAddress = 0x63099820ca5a4531d80707f9f556e070baf4373a9c431fa4e7679b7d0897084
        .try_into()
        .unwrap();
    pub const ALLOCATOR: ContractAddress = 0x4c99d9722f8a92c9ec8b4fcbcda34b3f421e6a606a96b3412d0814bd3950b37
        .try_into()
        .unwrap();
    pub const CARETAKER: ContractAddress = 0x588224a04816c800750e3cd42d6510c737522ae70364f68dc9d145ea5a3595c
        .try_into()
        .unwrap();
    pub const CONTROLLER: ContractAddress = 0x4f249023c640595451965915faae8331e91441d794459c2346c897de925237d
        .try_into()
        .unwrap();
    pub const EQUALIZER: ContractAddress = 0x5bf00e87b04e8ca30eb208ed73c4ba22c396a1356c19a139f4981008e07164e
        .try_into()
        .unwrap();
    pub const ETH_GATE: ContractAddress = 0x6625311551fa60639de710f028e4851452b716926516819fb3784aba3fced6b
        .try_into()
        .unwrap();
    pub const FLASH_MINT: ContractAddress = 0x1e7300a9bed6a5ac6cc511e256f92a3f8a72a6e549e6d9ace2df6efd22a9e87
        .try_into()
        .unwrap();
    pub const FRONTEND_DATA_PROVIDER: ContractAddress =
        0x1bc7e89cc9500af3ecbf17c23a1266592c7727f2ac8e55eb8b9772a8632c496
        .try_into()
        .unwrap();
    pub const MOCK_PRAGMA: ContractAddress = 0x6e87c3272ec2d2974404e28209af6ae1a04abd1b98278de729fc8870e819848
        .try_into()
        .unwrap();
    pub const PRAGMA: ContractAddress = 0x5c3a263e668c801cdc4c5e47e884f27a18ff2e23b60eb96463429bc6de6752c
        .try_into()
        .unwrap();
    pub const PURGER: ContractAddress = 0x5a5ff7047dfbc11bdef1e508b9c93243b56c87fcd60f5cb1de9cd83c0b8c5ac
        .try_into()
        .unwrap();
    pub const SEER: ContractAddress = 0x4c494a52d143345fd07ab3332e79ad5d88510d6987485a780ccad4469a6996a
        .try_into()
        .unwrap();
    pub const SENTINEL: ContractAddress = 0x337ba8343b351b666bc68d98c089be92f700c0c5b9fa3249d6f6e32d6b8460e
        .try_into()
        .unwrap();
    pub const SHRINE: ContractAddress = 0x617dddf396a9dfa0a4e7280d20c86a6fa127da450d4349b268c67429a485d05
        .try_into()
        .unwrap();
    pub const STRK_GATE: ContractAddress = 0x139bf2eec17ee49ef1ae720a64fe8cd38ee058637675f9a1229c86e8cdd837c
        .try_into()
        .unwrap();
    pub const USDC_TRANSMUTER_RESTRICTED: ContractAddress =
        0x54496baa43399f9fe1d84ea73ee58a72bd6fc889147c89c1586d35c86dfff0a
        .try_into()
        .unwrap();
    pub const USDC: ContractAddress = 0xb555576884d0052fa8ca06e05685947c905bb21bd9b2627016b01da41fac5e
        .try_into()
        .unwrap();
    pub const WBTC: ContractAddress = 0x45533574519d0351214e2a81201e199fe5d060e92f74fd8cbad39767d6a141a
        .try_into()
        .unwrap();
    pub const WBTC_GATE: ContractAddress = 0x2c076f39d9ae2b1c5bd58393a7fa9c02606e53b745cf91ac9cc8cfb792a2d1
        .try_into()
        .unwrap();
}

pub mod sepolia {
    use starknet::ContractAddress;

    pub const ADMIN: ContractAddress = 0x17721cd89df40d33907b70b42be2a524abeea23a572cf41c79ffe2422e7814e
        .try_into()
        .unwrap();

    pub const USDC: ContractAddress = 0x053b40a647cedfca6ca84f542a0fe36736031905a9639a7f19a3c1e66bfd5080
        .try_into()
        .unwrap();

    // https://github.com/Astraly-Labs/pragma-oracle?tab=readme-ov-file#deployment-addresses
    pub const PRAGMA_SPOT_ORACLE: ContractAddress = 0x36031daa264c24520b11d93af622c848b2499b66b41d611bac95e13cfca131a
        .try_into()
        .unwrap();
    pub const PRAGMA_TWAP_ORACLE: ContractAddress = 0x54563a0537b3ae0ba91032d674a6d468f30a59dc4deb8f0dce4e642b94be15c
        .try_into()
        .unwrap();

    // deployments
    pub const ABBOT: ContractAddress = 0x04280b97ecb8f1e0536e41888e387a04c3796e393f7086e5e24d61614927bc30
        .try_into()
        .unwrap();
    pub const ABSORBER: ContractAddress = 0x05cf86333b32580be7a73c8150f2176047bab151df7506b6e30217594798fab5
        .try_into()
        .unwrap();
    pub const ALLOCATOR: ContractAddress = 0x00dd24daea0f6cf5ee0a206e6a27c4d5b66a978f19e3a4877de23ab5a76f905d
        .try_into()
        .unwrap();
    pub const CARETAKER: ContractAddress = 0x004eb68cdc4009f0a7af80ecb34b91822649b139713e7e9eb9b11b10ee47aada
        .try_into()
        .unwrap();
    pub const CONTROLLER: ContractAddress = 0x0005efaa9df09e86be5aa8ffa453adc11977628ddc0cb493625ca0f3caaa94b2
        .try_into()
        .unwrap();
    pub const EQUALIZER: ContractAddress = 0x013be5f3de034ca1a0dec2b2da4cce2d0fe5505511cbea7a309979c45202d052
        .try_into()
        .unwrap();
    pub const ETH_GATE: ContractAddress = 0x02e1e0988565d99cd3a384e9f9cf2d348af50ee1ad549880aa37ba625e8c98d6
        .try_into()
        .unwrap();
    pub const FLASH_MINT: ContractAddress = 0x0726e7d7bef2bcfc2814e0d5f0735b1a9326a98f2307a5edfda8db82d60d3f5f
        .try_into()
        .unwrap();
    pub const FRONTEND_DATA_PROVIDER: ContractAddress =
        0x0348d8f672ea7f8f57ae45682571177a4d480301f36af45931bb197c37f6007a
        .try_into()
        .unwrap();
    pub const PRAGMA: ContractAddress = 0x02a67fac89d6921b05067b99e2491ce753778958ec89b0b0221b22c16a3073f7
        .try_into()
        .unwrap();
    pub const PURGER: ContractAddress = 0x0397fda455fd16d76995da81908931057594527b46cc99e12b8e579a9127e372
        .try_into()
        .unwrap();
    pub const SEER: ContractAddress = 0x07bdece1aeb7f2c31a90a6cc73dfdba1cb9055197cca24b6117c9e0895a1832d
        .try_into()
        .unwrap();
    pub const SENTINEL: ContractAddress = 0x04c4d997f2a4b1fbf9db9c290ea1c97cb596e7765e058978b25683efd88e586d
        .try_into()
        .unwrap();
    pub const SHRINE: ContractAddress = 0x0398c179d65929f3652b6b82875eaf5826ea1c9a9dd49271e0d749328186713e
        .try_into()
        .unwrap();
    pub const STRK_GATE: ContractAddress = 0x05c6ec6e1748fbab3d65c2aa7897aeb7d7ec843331c1a469666e162da735fd5f
        .try_into()
        .unwrap();
    pub const USDC_TRANSMUTER_RESTRICTED: ContractAddress =
        0x03280ae1d855fd195a63bc72fa19c2f8a9820b7871f34eff13e3841ff7388c81
        .try_into()
        .unwrap();
}

pub mod mainnet {
    use starknet::ContractAddress;

    pub const ADMIN: ContractAddress = 0x0684f8b5dd37cad41327891262cb17397fdb3daf54e861ec90f781c004972b15
        .try_into()
        .unwrap();
    pub const MULTISIG: ContractAddress = 0x00Ca40fCa4208A0c2a38fc81a66C171623aAC3B913A4365F7f0BC0EB3296573C
        .try_into()
        .unwrap();

    // Tokens
    //
    // Unless otherwise stated, token's address is available at:
    // https://github.com/starknet-io/starknet-addresses/blob/master/bridged_tokens/mainnet.json

    pub const DAI: ContractAddress = 0x05574eb6b8789a91466f902c380d978e472db68170ff82a5b650b95a58ddf4ad
        .try_into()
        .unwrap();
    pub const USDC: ContractAddress = 0x053c91253bc9682c04929ca02ed00b3e423f6710d2ee7e0d5ebb06f3ecf368a8
        .try_into()
        .unwrap();
    pub const USDT: ContractAddress = 0x068f5c6a61780768455de69077e07e89787839bf8166decfbf92b645209c0fb8
        .try_into()
        .unwrap();
    pub const WBTC: ContractAddress = 0x03fe2b97c1fd336e750087d68b9b867997fd64a2661ff3ca5a7c771641e8e7ac
        .try_into()
        .unwrap();
    pub const WSTETH: ContractAddress = 0x042b8f0484674ca266ac5d08e4ac6a3fe65bd3129795def2dca5c34ecc5f96d2
        .try_into()
        .unwrap();
    pub const WSTETH_CANONICAL: ContractAddress = 0x0057912720381af14b0e5c87aa4718ed5e527eab60b3801ebf702ab09139e38b
        .try_into()
        .unwrap();
    pub const XSTRK: ContractAddress = 0x028d709c875c0ceac3dce7065bec5328186dc89fe254527084d1689910954b0a
        .try_into()
        .unwrap();
    pub const SSTRK: ContractAddress = 0x0356f304b154d29d2a8fe22f1cb9107a9b564a733cf6b4cc47fd121ac1af90c9
        .try_into()
        .unwrap();
    pub const EKUBO_TOKEN: ContractAddress = 0x075afe6402ad5a5c20dd25e10ec3b3986acaa647b77e4ae24b0cbc9a54a27a87
        .try_into()
        .unwrap();

    // External

    // https://docs.ekubo.org/integration-guides/reference/contract-addresses
    pub const EKUBO_ORACLE_EXTENSION: ContractAddress =
        0x005e470ff654d834983a46b8f29dfa99963d5044b993cb7b9c92243a69dab38f
        .try_into()
        .unwrap();

    // https://github.com/Astraly-Labs/pragma-oracle?tab=readme-ov-file#deployment-addresses
    pub const PRAGMA_SPOT_ORACLE: ContractAddress = 0x2a85bd616f912537c50a49a4076db02c00b29b2cdc8a197ce92ed1837fa875b
        .try_into()
        .unwrap();
    pub const PRAGMA_TWAP_ORACLE: ContractAddress = 0x49eefafae944d07744d07cc72a5bf14728a6fb463c3eae5bca13552f5d455fd
        .try_into()
        .unwrap();

    // deployments
    pub const ABBOT: ContractAddress = 0x04d0bb0a4c40012384e7c419e6eb3c637b28e8363fb66958b60d90505b9c072f
        .try_into()
        .unwrap();
    pub const ABSORBER: ContractAddress = 0x000a5e1c1ffe1384b30a464a61b1af631e774ec52c0e7841b9b5f02c6a729bc0
        .try_into()
        .unwrap();
    pub const ALLOCATOR: ContractAddress = 0x06a3593f7115f8f5e0728995d8924229cb1c4109ea477655bad281b36a760f41
        .try_into()
        .unwrap();
    pub const CARETAKER: ContractAddress = 0x012a5efcb820803ba700503329567fcdddd7731e0d05e06217ed1152f956dbb0
        .try_into()
        .unwrap();
    pub const CONTROLLER: ContractAddress = 0x07558a9da2fac57f5a4381fef8c36c92ca66adc20978063982382846f72a4448
        .try_into()
        .unwrap();
    pub const EKUBO: ContractAddress = 0x048a1cc699025faec330b85ab74a7586e424206a481daed14160982b57567cce
        .try_into()
        .unwrap();
    pub const EQUALIZER: ContractAddress = 0x066e3e2ea2095b2a0424b9a2272e4058f30332df5ff226518d19c20d3ab8e842
        .try_into()
        .unwrap();
    pub const ETH_GATE: ContractAddress = 0x0315ce9c5d3e5772481181441369d8eea74303b9710a6c72e3fcbbdb83c0dab1
        .try_into()
        .unwrap();
    pub const FLASH_MINT: ContractAddress = 0x05e57a033bb3a03e8ac919cbb4e826faf8f3d6a58e76ff7a13854ffc78264681
        .try_into()
        .unwrap();
    pub const FRONTEND_DATA_PROVIDER: ContractAddress =
        0x023037703b187f6ff23b883624a0a9f266c9d44671e762048c70100c2f128ab9
        .try_into()
        .unwrap();
    pub const PRAGMA: ContractAddress = 0x0532f8b442e90eae93493a4f3e4f6d3bf2579e56a75238b786a5e90cb82fdfe9
        .try_into()
        .unwrap();
    pub const PURGER: ContractAddress = 0x02cef5286b554f4122a2070bbd492a95ad810774903c92633979ed54d51b04ca
        .try_into()
        .unwrap();
    pub const RECEPTOR: ContractAddress = 0x059c159d9a87a34f17c4991e81b0d937aaf86a29f682ce0951536265bd6a1678
        .try_into()
        .unwrap();
    pub const SEER: ContractAddress = 0x076baf9a48986ae11b144481aec7699823d7ebc5843f30cf47b053ebfe579824
        .try_into()
        .unwrap();
    pub const SENTINEL: ContractAddress = 0x06428ec3221f369792df13e7d59580902f1bfabd56a81d30224f4f282ba380cd
        .try_into()
        .unwrap();
    pub const SHRINE: ContractAddress = 0x0498edfaf50ca5855666a700c25dd629d577eb9afccdf3b5977aec79aee55ada
        .try_into()
        .unwrap();
    pub const SSTRK_GATE: ContractAddress = 0x03b709f3ab9bc072a195b907fb2c27688723b6e4abb812a8941def819f929bd8
        .try_into()
        .unwrap();
    pub const STRK_GATE: ContractAddress = 0x031a96fe18fe3fdab28822c82c81471f1802800723c8f3e209f1d9da53bc637d
        .try_into()
        .unwrap();
    pub const USDC_TRANSMUTER_RESTRICTED: ContractAddress =
        0x03878595db449e1af7de4fb0c99ddb01cac5f23f9eb921254f4b0723a64a23cb
        .try_into()
        .unwrap();
    pub const WBTC_GATE: ContractAddress = 0x05bc1c8a78667fac3bf9617903dbf2c1bfe3937e1d37ada3d8b86bf70fb7926e
        .try_into()
        .unwrap();
    pub const WSTETH_GATE: ContractAddress = 0x02d1e95661e7726022071c06a95cdae092595954096c373cde24a34bb3984cbf
        .try_into()
        .unwrap();
    pub const WSTETH_CANONICAL_GATE: ContractAddress =
        0x03dc297a3788751d6d02acfea1b5dcc21a0eee1d34317a91aea2fbd49113ea58
        .try_into()
        .unwrap();
    pub const XSTRK_GATE: ContractAddress = 0x028d709c875c0ceac3dce7065bec5328186dc89fe254527084d1689910954b0a
        .try_into()
        .unwrap();
    pub const EKUBO_GATE: ContractAddress = 0x06d44c6172f6b68fda893348d33be58b69f0add83ed480d1192d19bc4188c8f6
        .try_into()
        .unwrap();
}
