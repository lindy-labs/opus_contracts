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

    use aura::interfaces::IAbbot::{IAbbotDispatcher, IAbbotDispatcherTrait};
    use aura::interfaces::IAbsorber::{IAbsorberDispatcher, IAbsorberDispatcherTrait};
    use aura::interfaces::IGate::{IGateDispatcher, IGateDispatcherTrait};
    use aura::interfaces::IPurger::{IPurgerDispatcher, IPurgerDispatcherTrait};
    use aura::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use aura::utils::access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use aura::utils::wadray;
    use aura::utils::wadray::Wad;

    use aura::tests::absorber::utils::AbsorberUtils;
    use aura::tests::common;
    use aura::tests::external::utils::PragmaUtils;

    //
    // Address constants
    //

    fn admin() -> ContractAddress {
        contract_address_try_from_felt252('purger owner').unwrap()
    }

    fn searcher() -> ContractAddress {
        contract_address_try_from_felt252('searcher').unwrap()
    }

    //
    // Test setup helpers
    //

    fn purger_deploy() -> (
        IShrineDispatcher,
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

        (shrine, absorber, purger, yangs, gates)
    }

    fn funded_searcher(
        abbot: IAbbotDispatcher,
        yangs: Span<ContractAddress>,
        gates: Span<IGateDispatcher>,
        user: ContractAddress,
    ) -> u64 {
        let provided_amt: Wad = 10000000000000000000000_u128.into(); // 10_000 (Wad)
        common::open_trove_helper(abbot, user, yangs, AbsorberUtils::provider_asset_amts(), gates, provided_amt)
    }
}
