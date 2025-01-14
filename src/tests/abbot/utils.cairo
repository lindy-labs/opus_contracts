pub mod abbot_utils {
    use access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use core::num::traits::Zero;
    use opus::core::abbot::abbot as abbot_contract;
    use opus::core::roles::{sentinel_roles, shrine_roles};
    use opus::interfaces::IAbbot::{IAbbotDispatcher, IAbbotDispatcherTrait};
    use opus::interfaces::IGate::{IGateDispatcher, IGateDispatcherTrait};
    use opus::interfaces::ISentinel::{ISentinelDispatcher, ISentinelDispatcherTrait};
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::tests::common;
    use opus::tests::sentinel::utils::sentinel_utils;
    use opus::tests::shrine::utils::shrine_utils;
    use snforge_std::{declare, ContractClass, ContractClassTrait, start_prank, stop_prank, CheatTarget};
    use starknet::ContractAddress;
    use wadray::Wad;

    // Struct to group together all contract classes
    // needed for abbot tests
    #[derive(Copy, Drop)]
    pub struct AbbotTestClasses {
        pub abbot: Option<ContractClass>,
        pub sentinel: Option<ContractClass>,
        pub token: Option<ContractClass>,
        pub gate: Option<ContractClass>,
        pub shrine: Option<ContractClass>,
    }

    #[derive(Copy, Drop)]
    pub struct AbbotTestConfig {
        pub abbot: IAbbotDispatcher,
        pub sentinel: ISentinelDispatcher,
        pub shrine: IShrineDispatcher,
        pub yangs: Span<ContractAddress>,
        pub gates: Span<IGateDispatcher>
    }

    //
    // Constants
    //

    pub const OPEN_TROVE_FORGE_AMT: u128 = 2000000000000000000000; // 2_000 (Wad)
    pub const ETH_DEPOSIT_AMT: u128 = 10000000000000000000; // 10 (Wad);
    pub const WBTC_DEPOSIT_AMT: u128 = 50000000; // 0.5 (WBTC decimals);

    pub const SUBSEQUENT_ETH_DEPOSIT_AMT: u128 = 2345000000000000000; // 2.345 (Wad);
    pub const SUBSEQUENT_WBTC_DEPOSIT_AMT: u128 = 44300000; // 0.443 (WBTC decimals);

    //
    // Constant helpers
    //

    pub fn initial_asset_amts() -> Span<u128> {
        let mut asset_amts: Array<u128> = array![ETH_DEPOSIT_AMT * 10, WBTC_DEPOSIT_AMT * 10,];
        asset_amts.span()
    }

    pub fn open_trove_yang_asset_amts() -> Span<u128> {
        let mut asset_amts: Array<u128> = array![ETH_DEPOSIT_AMT, WBTC_DEPOSIT_AMT];
        asset_amts.span()
    }

    pub fn subsequent_deposit_amts() -> Span<u128> {
        let mut asset_amts: Array<u128> = array![SUBSEQUENT_ETH_DEPOSIT_AMT, SUBSEQUENT_WBTC_DEPOSIT_AMT];
        asset_amts.span()
    }

    //
    // Test setup helpers
    //

    pub fn declare_contracts() -> AbbotTestClasses {
        AbbotTestClasses {
            abbot: Option::Some(declare("abbot").unwrap()),
            sentinel: Option::Some(declare("sentinel").unwrap()),
            token: Option::Some(declare("erc20_mintable").unwrap()),
            gate: Option::Some(declare("gate").unwrap()),
            shrine: Option::Some(declare("shrine").unwrap()),
        }
    }

    pub fn abbot_deploy(classes: Option<AbbotTestClasses>) -> AbbotTestConfig {
        let classes = match classes {
            Option::Some(classes) => classes,
            Option::None => declare_contracts(),
        };
        let sentinel_utils::SentinelTestConfig { sentinel, shrine, yangs, gates } =
            sentinel_utils::deploy_sentinel_with_gates(
            Option::Some(
                sentinel_utils::SentinelTestClasses {
                    sentinel: classes.sentinel, token: classes.token, gate: classes.gate, shrine: classes.shrine
                }
            )
        );
        shrine_utils::setup_debt_ceiling(shrine.contract_address);

        let calldata: Array<felt252> = array![shrine.contract_address.into(), sentinel.contract_address.into()];

        let (abbot_addr, _) = classes.abbot.unwrap().deploy(@calldata).expect('abbot deploy failed');

        let abbot = IAbbotDispatcher { contract_address: abbot_addr };

        // Grant Shrine roles to Abbot
        start_prank(CheatTarget::One(shrine.contract_address), shrine_utils::admin());
        let shrine_ac = IAccessControlDispatcher { contract_address: shrine.contract_address };
        shrine_ac.grant_role(shrine_roles::abbot(), abbot_addr);

        // Grant Sentinel roles to Abbot
        start_prank(CheatTarget::One(sentinel.contract_address), sentinel_utils::admin());
        let sentinel_ac = IAccessControlDispatcher { contract_address: sentinel.contract_address };
        sentinel_ac.grant_role(sentinel_roles::abbot(), abbot_addr);

        stop_prank(CheatTarget::Multiple(array![shrine.contract_address, sentinel.contract_address]));

        AbbotTestConfig { shrine, sentinel, abbot, yangs, gates }
    }

    pub fn deploy_abbot_and_open_trove(
        classes: Option<AbbotTestClasses>
    ) -> (
        AbbotTestConfig,
        ContractAddress, // trove owner
        u64, // trove ID
        Span<u128>, // deposited yang asset amounts
        Wad, // forge amount
    ) {
        let abbot_test_config = abbot_deploy(classes);
        let trove_owner: ContractAddress = common::trove1_owner_addr();

        let forge_amt: Wad = OPEN_TROVE_FORGE_AMT.into();
        common::fund_user(trove_owner, abbot_test_config.yangs, initial_asset_amts());
        let deposited_amts: Span<u128> = open_trove_yang_asset_amts();
        let trove_id: u64 = common::open_trove_helper(
            abbot_test_config.abbot,
            trove_owner,
            abbot_test_config.yangs,
            deposited_amts,
            abbot_test_config.gates,
            forge_amt
        );

        (abbot_test_config, trove_owner, trove_id, deposited_amts, forge_amt)
    }
}
