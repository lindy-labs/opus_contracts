mod abbot_utils {
    use opus::core::abbot::abbot as abbot_contract;
    use opus::core::roles::{sentinel_roles, shrine_roles};
    use opus::interfaces::IAbbot::{IAbbotDispatcher, IAbbotDispatcherTrait};
    use opus::interfaces::IGate::{IGateDispatcher, IGateDispatcherTrait};
    use opus::interfaces::ISentinel::{ISentinelDispatcher, ISentinelDispatcherTrait};
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::tests::common;
    use opus::tests::sentinel::utils::sentinel_utils;
    use opus::tests::shrine::utils::shrine_utils;
    use opus::utils::access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use opus::utils::wadray::Wad;
    use opus::utils::wadray;

    use snforge_std::{start_prank, CheatTarget};
    use starknet::contract_address::ContractAddressZeroable;
    use starknet::{
        ClassHash, class_hash_try_from_felt252, ContractAddress, contract_address_to_felt252,
        deploy_syscall, SyscallResultTrait
    };

    //
    // Constants
    //

    const OPEN_TROVE_FORGE_AMT: u128 = 2000000000000000000000; // 2_000 (Wad)
    const ETH_DEPOSIT_AMT: u128 = 10000000000000000000; // 10 (Wad);
    const WBTC_DEPOSIT_AMT: u128 = 50000000; // 0.5 (WBTC decimals);

    const SUBSEQUENT_ETH_DEPOSIT_AMT: u128 = 2345000000000000000; // 2.345 (Wad);
    const SUBSEQUENT_WBTC_DEPOSIT_AMT: u128 = 44300000; // 0.443 (WBTC decimals);

    //
    // Constant helpers
    //

    fn initial_asset_amts() -> Span<u128> {
        let mut asset_amts: Array<u128> = array![ETH_DEPOSIT_AMT * 10, WBTC_DEPOSIT_AMT * 10,];
        asset_amts.span()
    }

    fn open_trove_yang_asset_amts() -> Span<u128> {
        let mut asset_amts: Array<u128> = array![ETH_DEPOSIT_AMT, WBTC_DEPOSIT_AMT];
        asset_amts.span()
    }

    fn subsequent_deposit_amts() -> Span<u128> {
        let mut asset_amts: Array<u128> = array![
            SUBSEQUENT_ETH_DEPOSIT_AMT, SUBSEQUENT_WBTC_DEPOSIT_AMT
        ];
        asset_amts.span()
    }

    //
    // Test setup helpers
    //

    fn abbot_deploy(
        salt: Option<felt252>
    ) -> (
        IShrineDispatcher,
        ISentinelDispatcher,
        IAbbotDispatcher,
        Span<ContractAddress>,
        Span<IGateDispatcher>
    ) {
        let (sentinel, shrine, yangs, gates) = sentinel_utils::deploy_sentinel_with_gates(salt);
        shrine_utils::setup_debt_ceiling(shrine.contract_address);

        let mut calldata: Array<felt252> = array![
            contract_address_to_felt252(shrine.contract_address),
            contract_address_to_felt252(sentinel.contract_address),
        ];

        let abbot_class_hash: ClassHash = class_hash_try_from_felt252(
            abbot_contract::TEST_CLASS_HASH
        )
            .unwrap();
        let (abbot_addr, _) = deploy_syscall(abbot_class_hash, 0, calldata.span(), false)
            .unwrap_syscall();

        let abbot = IAbbotDispatcher { contract_address: abbot_addr };

        // Grant Shrine roles to Abbot
        start_prank(CheatTarget::All, shrine_utils::admin());
        let shrine_ac = IAccessControlDispatcher { contract_address: shrine.contract_address };
        shrine_ac.grant_role(shrine_roles::abbot(), abbot_addr);

        // Grant Sentinel roles to Abbot
        start_prank(CheatTarget::All, sentinel_utils::admin());
        let sentinel_ac = IAccessControlDispatcher { contract_address: sentinel.contract_address };
        sentinel_ac.grant_role(sentinel_roles::abbot(), abbot_addr);

        start_prank(CheatTarget::All, ContractAddressZeroable::zero());

        (shrine, sentinel, abbot, yangs, gates)
    }

    fn deploy_abbot_and_open_trove() -> (
        IShrineDispatcher,
        ISentinelDispatcher,
        IAbbotDispatcher,
        Span<ContractAddress>,
        Span<IGateDispatcher>,
        ContractAddress, // trove owner
        u64, // trove ID
        Span<u128>, // deposited yang asset amounts
        Wad, // forge amount
    ) {
        let (shrine, sentinel, abbot, yangs, gates) = abbot_deploy(Option::None);
        let trove_owner: ContractAddress = common::trove1_owner_addr();

        let forge_amt: Wad = OPEN_TROVE_FORGE_AMT.into();
        common::fund_user(trove_owner, yangs, initial_asset_amts());
        let deposited_amts: Span<u128> = open_trove_yang_asset_amts();
        let trove_id: u64 = common::open_trove_helper(
            abbot, trove_owner, yangs, deposited_amts, gates, forge_amt
        );

        (shrine, sentinel, abbot, yangs, gates, trove_owner, trove_id, deposited_amts, forge_amt)
    }
}
