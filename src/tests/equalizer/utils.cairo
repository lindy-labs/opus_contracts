pub mod equalizer_utils {
    use core::num::traits::{One, Zero};
    use opus::core::roles::{equalizer_roles, shrine_roles};
    use opus::interfaces::IAllocator::IAllocatorDispatcher;
    use opus::interfaces::IEqualizer::IEqualizerDispatcher;
    use opus::interfaces::IShrine::IShrineDispatcher;
    use opus::tests::common;
    use opus::tests::shrine::utils::shrine_utils;
    use snforge_std::{ContractClass, ContractClassTrait, DeclareResultTrait, declare};
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

    pub const INITIAL_RECIPIENTS: [ContractAddress; 3] = [
        'recipient 1'.try_into().unwrap(), 'recipient 2'.try_into().unwrap(), 'recipient 3'.try_into().unwrap(),
    ];

    pub const NEW_RECIPIENTS: [ContractAddress; 4] = [
        'new recipient 1'.try_into().unwrap(),
        'new recipient 2'.try_into().unwrap(),
        'new recipient 3'.try_into().unwrap(),
        'new recipient 4'.try_into().unwrap(),
    ];

    pub fn initial_percentages() -> Span<Ray> {
        array![
            150000000000000000000000000_u128.into(), // 15% (Ray)
            500000000000000000000000000_u128.into(), // 50% (Ray)
            350000000000000000000000000_u128.into() // 35% (Ray)
        ]
            .span()
    }

    pub fn new_percentages() -> Span<Ray> {
        array![
            125000000000000000000000000_u128.into(), // 12.5% (Ray)
            372500000000000000000000000_u128.into(), // 37.25% (Ray)
            216350000000000000000000000_u128.into(), // 21.635% (Ray)
            286150000000000000000000000_u128.into() // 28.615% (Ray)
        ]
            .span()
    }

    // Percentages do not add to 1
    pub fn invalid_percentages() -> Span<Ray> {
        array![
            150000000000000000000000000_u128.into(), // 15% (Ray)
            500000000000000000000000000_u128.into(), // 50% (Ray)
            350000000000000000000000001_u128.into() // (35 + 1E-27)% (Ray)
        ]
            .span()
    }

    //
    // Test setup helpers
    //

    pub fn allocator_deploy(
        mut recipients: Span<ContractAddress>, mut percentages: Span<Ray>, allocator_class: Option<ContractClass>,
    ) -> IAllocatorDispatcher {
        let mut calldata: Array<felt252> = array![common::SHRINE_ADMIN.into()];
        recipients.serialize(ref calldata);
        percentages.serialize(ref calldata);

        let allocator_class = allocator_class.unwrap_or(*declare("allocator").unwrap().contract_class());
        let (allocator_addr, _) = allocator_class.deploy(@calldata).expect('failed allocator deploy');

        IAllocatorDispatcher { contract_address: allocator_addr }
    }

    pub fn tcr_allocator_deploy(
        shrine: ContractAddress,
        absorber: ContractAddress,
        stabilizer: ContractAddress,
        tcr_allocator_class: Option<ContractClass>,
    ) -> IAllocatorDispatcher {
        let mut calldata: Array<felt252> = array![
            shrine.into(), common::SHRINE_ADMIN.into(), absorber.into(), stabilizer.into(),
        ];

        let tcr_allocator_class = tcr_allocator_class.unwrap_or(*declare("tcr_allocator").unwrap().contract_class());
        let (tcr_allocator_addr, _) = tcr_allocator_class.deploy(@calldata).expect('failed tcr allocator deploy');

        IAllocatorDispatcher { contract_address: tcr_allocator_addr }
    }

    pub fn equalizer_deploy(allocator_class: Option<ContractClass>) -> EqualizerTestConfig {
        let shrine: IShrineDispatcher = shrine_utils::shrine_deploy_with_dummy_yangs_and_feed(Option::None);
        equalizer_deploy_with_shrine(shrine, allocator_class)
    }

    pub fn equalizer_deploy_with_shrine(
        shrine: IShrineDispatcher, allocator_class: Option<ContractClass>,
    ) -> EqualizerTestConfig {
        let allocator: IAllocatorDispatcher = allocator_deploy(
            INITIAL_RECIPIENTS.span(), initial_percentages(), allocator_class,
        );
        let admin = common::SHRINE_ADMIN;

        let mut calldata: Array<felt252> = array![
            admin.into(), shrine.contract_address.into(), allocator.contract_address.into(),
        ];

        let equalizer_class = declare("equalizer").unwrap().contract_class();
        let (equalizer_addr, _) = equalizer_class.deploy(@calldata).expect('failed equalizer deploy');

        common::grant_role_for_address(equalizer_addr, equalizer_roles::ADMIN, admin);

        common::grant_role_for_address(shrine.contract_address, shrine_roles::EQUALIZER, equalizer_addr);

        let equalizer = IEqualizerDispatcher { contract_address: equalizer_addr };
        EqualizerTestConfig { shrine, equalizer, allocator }
    }

    // Assertion helpers

    pub fn sums_to_one(percentages: Span<Ray>) {
        let mut sum: Ray = Zero::zero();
        for percentage in percentages {
            sum += *percentage;
        }
        assert(sum.is_one(), 'pct sum not 100%');
    }
}
