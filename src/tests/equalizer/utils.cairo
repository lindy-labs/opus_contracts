pub mod equalizer_utils {
    use access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use core::num::traits::Zero;
    use opus::core::allocator::allocator as allocator_contract;
    use opus::core::equalizer::equalizer as equalizer_contract;
    use opus::core::roles::{equalizer_roles, shrine_roles};
    use opus::interfaces::IAllocator::{IAllocatorDispatcher, IAllocatorDispatcherTrait};
    use opus::interfaces::IEqualizer::{IEqualizerDispatcher, IEqualizerDispatcherTrait};
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::tests::shrine::utils::shrine_utils;
    use snforge_std::{
        CheatTarget, ContractClass, ContractClassTrait, declare, start_cheat_caller_address, stop_cheat_caller_address,
    };
    use starknet::ContractAddress;
    use wadray::Ray;

    #[derive(Copy, Drop)]
    pub struct EqualizerTestConfig {
        pub allocator: IAllocatorDispatcher,
        pub equalizer: IEqualizerDispatcher,
        pub shrine: IShrineDispatcher,
    }

    //
    // Convenience helpers
    //

    pub fn initial_recipients() -> Span<ContractAddress> {
        let mut recipients: Array<ContractAddress> = array![
            'recipient 1'.try_into().unwrap(), 'recipient 2'.try_into().unwrap(), 'recipient 3'.try_into().unwrap(),
        ];
        recipients.span()
    }

    pub fn new_recipients() -> Span<ContractAddress> {
        let mut recipients: Array<ContractAddress> = array![
            'new recipient 1'.try_into().unwrap(),
            'new recipient 2'.try_into().unwrap(),
            'new recipient 3'.try_into().unwrap(),
            'new recipient 4'.try_into().unwrap(),
        ];
        recipients.span()
    }

    pub fn initial_percentages() -> Span<Ray> {
        let mut percentages: Array<Ray> = array![
            150000000000000000000000000_u128.into(), // 15% (Ray)
            500000000000000000000000000_u128.into(), // 50% (Ray)
            350000000000000000000000000_u128.into() // 35% (Ray)
        ];
        percentages.span()
    }

    pub fn new_percentages() -> Span<Ray> {
        let mut percentages: Array<Ray> = array![
            125000000000000000000000000_u128.into(), // 12.5% (Ray)
            372500000000000000000000000_u128.into(), // 37.25% (Ray)
            216350000000000000000000000_u128.into(), // 21.635% (Ray)
            286150000000000000000000000_u128.into() // 28.615% (Ray)
        ];
        percentages.span()
    }

    // Percentages do not add to 1
    pub fn invalid_percentages() -> Span<Ray> {
        let mut percentages: Array<Ray> = array![
            150000000000000000000000000_u128.into(), // 15% (Ray)
            500000000000000000000000000_u128.into(), // 50% (Ray)
            350000000000000000000000001_u128.into() // (35 + 1E-27)% (Ray)
        ];
        percentages.span()
    }

    //
    // Test setup helpers
    //

    pub fn allocator_deploy(
        mut recipients: Span<ContractAddress>, mut percentages: Span<Ray>, allocator_class: Option<ContractClass>,
    ) -> IAllocatorDispatcher {
        let mut calldata: Array<felt252> = array![shrine_utils::admin().into(), recipients.len().into()];

        loop {
            match recipients.pop_front() {
                Option::Some(recipient) => { calldata.append((*recipient).into()); },
                Option::None => { break; },
            };
        };

        calldata.append(percentages.len().into());
        loop {
            match percentages.pop_front() {
                Option::Some(percentage) => {
                    let val: felt252 = (*percentage.val).into();
                    calldata.append(val);
                },
                Option::None => { break; },
            };
        };

        let allocator_class = match allocator_class {
            Option::Some(class) => class,
            Option::None => declare("allocator").unwrap(),
        };
        let (allocator_addr, _) = allocator_class.deploy(@calldata).expect('failed allocator deploy');

        IAllocatorDispatcher { contract_address: allocator_addr }
    }

    pub fn equalizer_deploy(allocator_class: Option<ContractClass>) -> EqualizerTestConfig {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);
        equalizer_deploy_with_shrine(shrine.contract_address, allocator_class)
    }

    pub fn equalizer_deploy_with_shrine(
        shrine: ContractAddress, allocator_class: Option<ContractClass>,
    ) -> EqualizerTestConfig {
        let allocator: IAllocatorDispatcher = allocator_deploy(
            initial_recipients(), initial_percentages(), allocator_class,
        );
        let admin = shrine_utils::admin();

        let mut calldata: Array<felt252> = array![admin.into(), shrine.into(), allocator.contract_address.into()];

        let equalizer_class = declare("equalizer").unwrap().contract_class();
        let (equalizer_addr, _) = equalizer_class.deploy(@calldata).expect('failed equalizer deploy');

        let equalizer_ac: IAccessControlDispatcher = IAccessControlDispatcher { contract_address: equalizer_addr };
        start_cheat_caller_address(CheatTarget::Multiple(array![equalizer_addr, shrine]), admin);
        equalizer_ac.grant_role(equalizer_roles::default_admin_role(), admin);

        let shrine_ac: IAccessControlDispatcher = IAccessControlDispatcher { contract_address: shrine };
        shrine_ac.grant_role(shrine_roles::equalizer(), equalizer_addr);

        stop_cheat_caller_address(CheatTarget::Multiple(array![equalizer_addr, shrine]));

        EqualizerTestConfig {
            shrine: IShrineDispatcher { contract_address: shrine },
            equalizer: IEqualizerDispatcher { contract_address: equalizer_addr },
            allocator,
        }
    }
}
