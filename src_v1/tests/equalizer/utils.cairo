mod EqualizerUtils {
    use array::{ArrayTrait, SpanTrait};
    use option::OptionTrait;
    use traits::{Default, Into};
    use starknet::{
        contract_address_const, deploy_syscall, ClassHash, class_hash_try_from_felt252,
        ContractAddress, contract_address_to_felt252, SyscallResultTrait
    };
    use starknet::contract_address::ContractAddressZeroable;
    use starknet::testing::set_contract_address;

    use aura::core::allocator::Allocator;
    use aura::core::equalizer::Equalizer;
    use aura::core::roles::ShrineRoles;

    use aura::interfaces::IAllocator::{IAllocatorDispatcher, IAllocatorDispatcherTrait};
    use aura::interfaces::IEqualizer::{IEqualizerDispatcher, IEqualizerDispatcherTrait};
    use aura::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use aura::utils::access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use aura::utils::serde;
    use aura::utils::wadray;
    use aura::utils::wadray::Ray;

    use aura::tests::shrine::utils::ShrineUtils;

    //
    // Convenience helpers
    //

    fn initial_recipients() -> Span<ContractAddress> {
        let mut recipients: Array<ContractAddress> = Default::default();
        recipients.append(contract_address_const::<0x12341234>());
        recipients.append(contract_address_const::<0x23412341>());
        recipients.append(contract_address_const::<0x34123412>());

        recipients.span()
    }

    fn new_recipients() -> Span<ContractAddress> {
        let mut recipients: Array<ContractAddress> = Default::default();
        recipients.append(contract_address_const::<0x34563456>());
        recipients.append(contract_address_const::<0x45634563>());
        recipients.append(contract_address_const::<0x56345634>());
        recipients.append(contract_address_const::<0x63456345>());

        recipients.span()
    }

    fn initial_percentages() -> Span<Ray> {
        let mut percentages: Array<Ray> = Default::default();
        percentages.append(150000000000000000000000000_u128.into()); // 15% (Ray)
        percentages.append(500000000000000000000000000_u128.into()); // 50% (Ray)
        percentages.append(350000000000000000000000000_u128.into()); // 35% (Ray)

        percentages.span()
    }

    fn new_percentages() -> Span<Ray> {
        let mut percentages: Array<Ray> = Default::default();
        percentages.append(125000000000000000000000000_u128.into()); // 12.5% (Ray)
        percentages.append(372500000000000000000000000_u128.into()); // 37.25% (Ray)
        percentages.append(216350000000000000000000000_u128.into()); // 21.635% (Ray)
        percentages.append(286150000000000000000000000_u128.into()); // 28.615% (Ray)

        percentages.span()
    }

    // Percentages do not add to 1
    fn invalid_percentages() -> Span<Ray> {
        let mut percentages: Array<Ray> = Default::default();
        percentages.append(150000000000000000000000000_u128.into()); // 15% (Ray)
        percentages.append(500000000000000000000000000_u128.into()); // 50% (Ray)
        percentages.append(350000000000000000000000001_u128.into()); // (35 + 1E-27)% (Ray)

        percentages.span()
    }

    //
    // Test setup helpers
    //

    fn allocator_deploy(
        mut recipients: Span<ContractAddress>, mut percentages: Span<Ray>
    ) -> IAllocatorDispatcher {
        let mut calldata = Default::default();
        calldata.append(contract_address_to_felt252(ShrineUtils::admin()));

        calldata.append(recipients.len().into());
        loop {
            match recipients.pop_front() {
                Option::Some(recipient) => {
                    calldata.append(contract_address_to_felt252(*recipient));
                },
                Option::None(_) => {
                    break;
                }
            };
        };

        calldata.append(percentages.len().into());
        loop {
            match percentages.pop_front() {
                Option::Some(percentage) => {
                    let val: felt252 = (*percentage.val).into();
                    calldata.append(val);
                },
                Option::None(_) => {
                    break;
                }
            };
        };

        let allocator_class_hash: ClassHash = class_hash_try_from_felt252(
            Allocator::TEST_CLASS_HASH
        )
            .unwrap();
        let (allocator_addr, _) = deploy_syscall(allocator_class_hash, 0, calldata.span(), false)
            .unwrap_syscall();

        IAllocatorDispatcher { contract_address: allocator_addr }
    }

    fn equalizer_deploy() -> (IShrineDispatcher, IEqualizerDispatcher, IAllocatorDispatcher) {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();
        equalizer_deploy_with_shrine(shrine.contract_address)
    }

    fn equalizer_deploy_with_shrine(shrine: ContractAddress) -> (IShrineDispatcher, IEqualizerDispatcher, IAllocatorDispatcher) {
        let allocator: IAllocatorDispatcher = allocator_deploy(
            initial_recipients(), initial_percentages()
        );
        let admin = ShrineUtils::admin();

        let mut calldata = Default::default();
        calldata.append(contract_address_to_felt252(admin));
        calldata.append(contract_address_to_felt252(shrine));
        calldata.append(contract_address_to_felt252(allocator.contract_address));

        let equalizer_class_hash: ClassHash = class_hash_try_from_felt252(
            Equalizer::TEST_CLASS_HASH
        )
            .unwrap();
        let (equalizer_addr, _) = deploy_syscall(equalizer_class_hash, 0, calldata.span(), false)
            .unwrap_syscall();

        set_contract_address(admin);
        let shrine_ac: IAccessControlDispatcher = IAccessControlDispatcher {
            contract_address: shrine
        };
        shrine_ac.grant_role(ShrineRoles::INJECT, equalizer_addr);

        set_contract_address(ContractAddressZeroable::zero());

        (IShrineDispatcher { contract_address: shrine }, IEqualizerDispatcher { contract_address: equalizer_addr }, allocator)
    }
}