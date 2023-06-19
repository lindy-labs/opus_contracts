mod PurgerUtils {
    use array::{ArrayTrait, SpanTrait};
    use integer::BoundedU256;
    use option::OptionTrait;
    use starknet::{
        contract_address_const, deploy_syscall, ClassHash, class_hash_try_from_felt252,
        ContractAddress, contract_address_to_felt252, contract_address_try_from_felt252,
        SyscallResultTrait
    };
    use starknet::contract_address::ContractAddressZeroable;
    use starknet::testing::set_contract_address;
    use traits::{Default, Into, TryInto};
    use zeroable::Zeroable;

    use aura::core::purger::Purger;
    use aura::core::roles::{AbsorberRoles, PragmaRoles, SentinelRoles, ShrineRoles};

    use aura::interfaces::IAbbot::{IAbbotDispatcher, IAbbotDispatcherTrait};
    use aura::interfaces::IAbsorber::{IAbsorberDispatcher, IAbsorberDispatcherTrait};
    use aura::interfaces::IGate::{IGateDispatcher, IGateDispatcherTrait};
    use aura::interfaces::IPurger::{IPurgerDispatcher, IPurgerDispatcherTrait};
    use aura::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use aura::utils::access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use aura::utils::wadray;
    use aura::utils::wadray::{Ray, RAY_ONE, Wad, WAD_ONE};

    use aura::tests::abbot::utils::AbbotUtils;
    use aura::tests::absorber::utils::AbsorberUtils;
    use aura::tests::common;
    use aura::tests::external::utils::PragmaUtils;
    use aura::tests::sentinel::utils::SentinelUtils;
    use aura::tests::shrine::utils::ShrineUtils;

    use debug::PrintTrait;

    //
    // Address constants
    //

    fn admin() -> ContractAddress {
        contract_address_try_from_felt252('purger owner').unwrap()
    }

    fn searcher() -> ContractAddress {
        contract_address_try_from_felt252('searcher').unwrap()
    }

    fn target_trove_owner() -> ContractAddress {
        contract_address_try_from_felt252('target trove owner').unwrap()
    }

    //
    // Constants
    //


    //
    // Test setup helpers
    //

    fn purger_deploy() -> (
        IShrineDispatcher,
        IAbbotDispatcher,
        IAbsorberDispatcher,
        IPurgerDispatcher,
        Span<ContractAddress>,
        Span<IGateDispatcher>,
    ) {
        let (shrine, sentinel, abbot, absorber, yangs, gates, provider, provided_amt) = AbsorberUtils::absorber_with_first_provider();
        let (_, oracle, _, _) = PragmaUtils::pragma_deploy_with_shrine(sentinel, shrine.contract_address);
        PragmaUtils::add_yangs_to_pragma(oracle, yangs);

        let admin: ContractAddress = admin();

        let mut calldata = Default::default();
        //calldata.append(contract_address_to_felt252(admin));
        calldata.append(contract_address_to_felt252(shrine.contract_address));
        calldata.append(contract_address_to_felt252(sentinel.contract_address));
        calldata.append(contract_address_to_felt252(absorber.contract_address));
        calldata.append(contract_address_to_felt252(oracle.contract_address));

        let purger_class_hash: ClassHash = class_hash_try_from_felt252(Purger::TEST_CLASS_HASH)
            .unwrap();
        let (purger_addr, _) = deploy_syscall(purger_class_hash, 0, calldata.span(), false)
            .unwrap_syscall();

        let purger = IPurgerDispatcher { contract_address: purger_addr };

        // Approve Purger in Shrine
        let shrine_ac = IAccessControlDispatcher { contract_address: shrine.contract_address };
        set_contract_address(ShrineUtils::admin());
        shrine_ac.grant_role(ShrineRoles::purger(), purger_addr);

        // Approve Purger in Sentinel
        let sentinel_ac = IAccessControlDispatcher { contract_address: sentinel.contract_address };
        set_contract_address(SentinelUtils::admin());
        sentinel_ac.grant_role(SentinelRoles::purger(), purger_addr);

        // Approve Purger in Oracle
        let oracle_ac = IAccessControlDispatcher { contract_address: oracle.contract_address };
        set_contract_address(PragmaUtils::admin());
        oracle_ac.grant_role(PragmaRoles::purger(), purger_addr);

        // Approve Purger in Absorber
        let absorber_ac = IAccessControlDispatcher { contract_address: absorber.contract_address };
        set_contract_address(AbsorberUtils::admin());
        absorber_ac.grant_role(AbsorberRoles::purger(), purger_addr);

        // Increase debt ceiling
        set_contract_address(ShrineUtils::admin());
        let debt_ceiling: Wad = (100000 * WAD_ONE).into();
        shrine.set_debt_ceiling(debt_ceiling);

        set_contract_address(ContractAddressZeroable::zero());

        (shrine, abbot, absorber, purger, yangs, gates)
    }

    fn purger_deploy_with_searcher() -> (
        IShrineDispatcher,
        IAbbotDispatcher,
        IAbsorberDispatcher,
        IPurgerDispatcher,
        Span<ContractAddress>,
        Span<IGateDispatcher>,
    ) {
        let (shrine, abbot, absorber, purger, yangs, gates) = purger_deploy();
        funded_searcher(abbot, yangs, gates);

        (shrine, abbot, absorber, purger, yangs, gates)
    }

    fn funded_searcher(
        abbot: IAbbotDispatcher,
        yangs: Span<ContractAddress>,
        gates: Span<IGateDispatcher>,
    ) {
        let provided_amt: Wad = 10000000000000000000000_u128.into(); // 10_000 (Wad)
        let user: ContractAddress = searcher();
        common::fund_user(user, yangs, AbbotUtils::initial_asset_amts());
        common::open_trove_helper(abbot, user, yangs, AbsorberUtils::provider_asset_amts(), gates, provided_amt);
    }

    // Creates a healthy trove and returns the trove ID
    fn funded_healthy_trove(
        abbot: IAbbotDispatcher,
        yangs: Span<ContractAddress>,
        gates: Span<IGateDispatcher>,
    ) -> u64 {
        let provided_amt: Wad = 1000000000000000000000_u128.into(); // 1000 (Wad)
        let user: ContractAddress = target_trove_owner();
        common::fund_user(user, yangs, AbbotUtils::initial_asset_amts());
        let deposit_amts: Span<u128> = common::transform_span_by_pct(
            AbsorberUtils::provider_asset_amts(), 
            200000000000000000000000000_u128.into() // 20% (Ray)
        );
        common::open_trove_helper(abbot, user, yangs, deposit_amts, gates, provided_amt)
    }

    // Update thresholds for all yangs to the given value
    fn set_thresholds(shrine: IShrineDispatcher, mut yangs: Span<ContractAddress>, threshold: Ray) {
        set_contract_address(ShrineUtils::admin());
        loop {
            match yangs.pop_front() {
                Option::Some(yang) => {
                    shrine.set_threshold(*yang, threshold);
                },
                Option::None(_) => {
                    break;
                },
            }; 
        };
        set_contract_address(ContractAddressZeroable::zero());
    }

    fn decrease_yang_prices_by_pct(
        shrine: IShrineDispatcher,
        mut yangs: Span<ContractAddress>,
        pct_decrease: Ray,
    ) {
        set_contract_address(ShrineUtils::admin());
        loop {
            match yangs.pop_front() {
                Option::Some(yang) => {
                    let (yang_price, _, _) = shrine.get_current_yang_price(*yang);
                    let new_price: Wad = wadray::rmul_wr(yang_price, (RAY_ONE.into() - pct_decrease));
                    shrine.advance(*yang, new_price);
                },
                Option::None(_) => {
                    break;
                },
            }; 
        };
        set_contract_address(ContractAddressZeroable::zero());
    }
}
