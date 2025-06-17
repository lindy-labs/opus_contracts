#[starknet::contract]
pub mod tcr_allocator {
    use opus::interfaces::IAllocator::IAllocator;
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::types::Health;
    use starknet::ContractAddress;
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
    use wadray::{RAY_PERCENT, Ray};

    //
    // Constants
    //

    pub const ADMIN_FEE_RECIPIENT_PCT: u128 = 20 * RAY_PERCENT;

    // Minimum and maximum allocated percentages for Absorber and Stabilizer
    pub const MIN_ADJUSTABLE_PCT: u128 = 20 * RAY_PERCENT;
    pub const MAX_ADJUSTABLE_PCT: u128 = 60 * RAY_PERCENT;

    pub const TOTAL_ADJUSTABLE_PCT: u128 = MIN_ADJUSTABLE_PCT + MAX_ADJUSTABLE_PCT;
    pub const ADJUSTABLE_PCT_RANGE: u128 = MAX_ADJUSTABLE_PCT - MIN_ADJUSTABLE_PCT;

    // Factor to be applied to the Shrine's threshold to determine
    // the minimum protocol LTV at which the allocation between Absorber and Stabilizer
    // moves from (MIN_ADJUSTABLE_PCT, MAX_ADJUSTABLE_PCT) towards
    // (MAX_ADJUSTABLE_PCT, MIN_ADJUSTABLE_PCT).
    pub const MIN_LTV_ADJUSTMENT_FACTOR: u128 = 60 * RAY_PERCENT;

    //
    // Storage
    //

    #[storage]
    struct Storage {
        shrine: IShrineDispatcher,
        admin_fee_recipient: ContractAddress,
        absorber: ContractAddress,
        stabilizer: ContractAddress,
    }

    //
    // Constructor
    //

    #[constructor]
    fn constructor(
        ref self: ContractState,
        shrine: ContractAddress,
        admin_fee_recipient: ContractAddress,
        absorber: ContractAddress,
        stabilizer: ContractAddress,
    ) {
        self.shrine.write(IShrineDispatcher { contract_address: shrine });
        self.admin_fee_recipient.write(admin_fee_recipient);
        self.absorber.write(absorber);
        self.stabilizer.write(stabilizer);
    }

    //
    // External TCR Allocator functions
    //

    #[abi(embed_v0)]
    impl IAllocatorImpl of IAllocator<ContractState> {
        //
        // Getters
        //

        // Returns a tuple of ordered arrays of recipients' addresses and their respective
        // percentage share of newly minted surplus debt.
        fn get_allocation(self: @ContractState) -> (Span<ContractAddress>, Span<Ray>) {
            let recipients: Span<ContractAddress> = array![
                self.admin_fee_recipient.read(), self.absorber.read(), self.stabilizer.read(),
            ]
                .span();

            let (absorber_pct, stabilizer_pct) = self.get_adjustable_percentages();
            let percentages: Span<Ray> = array![ADMIN_FEE_RECIPIENT_PCT.into(), absorber_pct, stabilizer_pct].span();

            (recipients, percentages)
        }

        //
        // Setters
        //

        // Placeholder
        fn set_allocation(ref self: ContractState, recipients: Span<ContractAddress>, percentages: Span<Ray>) {
            return;
        }
    }

    //
    // Internal TCR Allocator functions
    //

    #[generate_trait]
    impl AllocatorHelpers of AllocatorHelpersTrait {
        // The allocation between the Absorber and Stabilizer is adjusted as follows:
        // - If the protocol LTV is at or below the minimum LTV for adjustment, then the allocation
        //   will be (MIN_ADJUSTABLE_PCT, MAX_ADJUSTABLE_PCT).
        // - If the protocol LTV is greater than the minimum LTV for adjustment but at or below
        //   the recovery mode LTV, then as LTV increases, the allocation shifts linearly from
        //   (MIN_ADJUSTABLE_PCT, MAX_ADJUSTABLE_PCT) to (MAX_ADJUSTABLE_PCT, MIN_ADJUSTABLE_PCT).
        // - If the protocol LTV is greater than the recovery mode LTV (i.e. recovery mode is triggered),
        //   then the allocation will be (MAX_ADJUSTABLE_PCT, MIN_ADJUSTABLE_PCT).
        fn get_adjustable_percentages(self: @ContractState) -> (Ray, Ray) {
            let shrine = self.shrine.read();
            let shrine_health: Health = shrine.get_shrine_health();

            let min_ltv_to_adjust: Ray = MIN_LTV_ADJUSTMENT_FACTOR.into() * shrine_health.threshold;
            let recovery_mode_target_factor: Ray = shrine.get_recovery_mode_target_factor();
            let recovery_mode_target_ltv: Ray = recovery_mode_target_factor * shrine_health.threshold;
            if shrine_health.ltv <= min_ltv_to_adjust {
                (MIN_ADJUSTABLE_PCT.into(), MAX_ADJUSTABLE_PCT.into())
            } else if shrine_health.ltv > recovery_mode_target_ltv {
                (MAX_ADJUSTABLE_PCT.into(), MIN_ADJUSTABLE_PCT.into())
            } else {
                let ltv_range: Ray = recovery_mode_target_ltv - min_ltv_to_adjust;
                let adjustment: Ray = (shrine_health.ltv - min_ltv_to_adjust) / ltv_range * ADJUSTABLE_PCT_RANGE.into();

                let absorber_pct: Ray = MIN_ADJUSTABLE_PCT.into() + adjustment;
                let stabilizer_pct: Ray = TOTAL_ADJUSTABLE_PCT.into() - absorber_pct;
                (absorber_pct, stabilizer_pct)
            }
        }
    }
}
