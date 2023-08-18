mod AbbotUtils {
    use array::{ArrayTrait, SpanTrait};
    use option::OptionTrait;
    use starknet::{
        ClassHash, class_hash_try_from_felt252, ContractAddress, contract_address_to_felt252,
        deploy_syscall, SyscallResultTrait
    };
    use starknet::contract_address::ContractAddressZeroable;
    use starknet::testing::set_contract_address;
    use traits::{Default, Into};

    use aura::core::abbot::Abbot;
    use aura::core::roles::SentinelRoles;
    use aura::core::roles::ShrineRoles;

    use aura::interfaces::IAbbot::{IAbbotDispatcher, IAbbotDispatcherTrait};
    use aura::interfaces::IGate::{IGateDispatcher, IGateDispatcherTrait};
    use aura::interfaces::ISentinel::{ISentinelDispatcher, ISentinelDispatcherTrait};
    use aura::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use aura::utils::access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use aura::utils::wadray;
    use aura::utils::wadray::Wad;

    use aura::tests::common;
    use aura::tests::sentinel::utils::SentinelUtils;
    use aura::tests::shrine::utils::ShrineUtils;

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
        let mut asset_amts: Array<u128> = Default::default();
        asset_amts.append(ETH_DEPOSIT_AMT * 10);
        asset_amts.append(WBTC_DEPOSIT_AMT * 10);
        asset_amts.span()
    }

    fn open_trove_yang_asset_amts() -> Span<u128> {
        let mut asset_amts: Array<u128> = Default::default();
        asset_amts.append(ETH_DEPOSIT_AMT);
        asset_amts.append(WBTC_DEPOSIT_AMT);
        asset_amts.span()
    }

    fn subsequent_deposit_amts() -> Span<u128> {
        let mut asset_amts: Array<u128> = Default::default();
        asset_amts.append(SUBSEQUENT_ETH_DEPOSIT_AMT);
        asset_amts.append(SUBSEQUENT_WBTC_DEPOSIT_AMT);
        asset_amts.span()
    }

    //
    // Test setup helpers
    //

    fn abbot_deploy() -> (
        IShrineDispatcher,
        ISentinelDispatcher,
        IAbbotDispatcher,
        Span<ContractAddress>,
        Span<IGateDispatcher>
    ) {
        let (sentinel, shrine, yangs, gates) = SentinelUtils::deploy_sentinel_with_gates();
        ShrineUtils::setup_debt_ceiling(shrine.contract_address);

        let mut calldata = Default::default();
        calldata.append(contract_address_to_felt252(shrine.contract_address));
        calldata.append(contract_address_to_felt252(sentinel.contract_address));

        let abbot_class_hash: ClassHash = class_hash_try_from_felt252(Abbot::TEST_CLASS_HASH)
            .unwrap();
        let (abbot_addr, _) = deploy_syscall(abbot_class_hash, 0, calldata.span(), false)
            .unwrap_syscall();

        let abbot = IAbbotDispatcher { contract_address: abbot_addr };

        // Grant Shrine roles to Abbot
        set_contract_address(ShrineUtils::admin());
        let shrine_ac = IAccessControlDispatcher { contract_address: shrine.contract_address };
        shrine_ac.grant_role(ShrineRoles::abbot(), abbot_addr);

        // Grant Sentinel roles to Abbot
        set_contract_address(SentinelUtils::admin());
        let sentinel_ac = IAccessControlDispatcher { contract_address: sentinel.contract_address };
        sentinel_ac.grant_role(SentinelRoles::abbot(), abbot_addr);

        set_contract_address(ContractAddressZeroable::zero());

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
        let (shrine, sentinel, abbot, yangs, gates) = abbot_deploy();
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
