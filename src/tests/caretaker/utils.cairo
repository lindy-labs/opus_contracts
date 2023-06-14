mod CaretakerUtils {
    use array::{ArrayTrait, SpanTrait};
    use debug::PrintTrait;
    use option::OptionTrait;
    use starknet::{
        ClassHash, class_hash_try_from_felt252, ContractAddress, contract_address_const, contract_address_try_from_felt252,
        contract_address_to_felt252, deploy_syscall, SyscallResultTrait
    };
    use starknet::testing::{set_block_timestamp, set_contract_address};
    use traits::Default;

    use aura::core::caretaker::Caretaker;
    use aura::core::roles::ShrineRoles;

    use aura::utils::access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};

    use aura::tests::shrine::utils::ShrineUtils;
    use aura::tests::equalizer::utils::EqualizerUtils;
    use aura::tests::sentinel::utils::SentinelUtils;

    fn admin() -> ContractAddress {
        contract_address_try_from_felt252('caretaker admin').unwrap()
    }
    fn badguy() -> ContractAddress {
        contract_address_try_from_felt252('caretaker bad guy').unwrap()
    }

    // returns the addrs of caretaker, shrine, abbot, sentinel
    fn caretaker_deploy() -> (ContractAddress, ContractAddress, ContractAddress, ContractAddress) {
        set_block_timestamp(ShrineUtils::DEPLOYMENT_TIMESTAMP);

        let (sentinel, shrine, _assets, _gates) = SentinelUtils::deploy_sentinel_with_gates();
        let (shrine, equalizer, _allocator) = EqualizerUtils::equalizer_deploy_with_shrine(shrine.contract_address);
        let abbot = SentinelUtils::mock_abbot();

        let mut calldata: Array<felt252> = Default::default();
        calldata.append(contract_address_to_felt252(admin()));
        calldata.append(contract_address_to_felt252(shrine.contract_address));
        calldata.append(contract_address_to_felt252(abbot));
        calldata.append(contract_address_to_felt252(sentinel.contract_address));
        calldata.append(contract_address_to_felt252(equalizer.contract_address));

        let caretaker_class_hash: ClassHash = class_hash_try_from_felt252(
            Caretaker::TEST_CLASS_HASH
        ).unwrap();
        let (caretaker, _) = deploy_syscall(caretaker_class_hash, 0, calldata.span(), false)
            .unwrap_syscall();

        // allow Caretaker to kill Shrine
        set_contract_address(ShrineUtils::admin());
        IAccessControlDispatcher { contract_address: shrine.contract_address }.grant_role(ShrineRoles::KILL, caretaker);

        (caretaker, shrine.contract_address, abbot, sentinel.contract_address)
    }

    // open troves, add yang, forge yin
    fn setup_system() {
        // TODO: need real abbot, merge those tests first
    }
}
