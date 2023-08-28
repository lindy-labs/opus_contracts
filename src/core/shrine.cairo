#[starknet::contract]
mod Shrine {
    use array::{ArrayTrait, SpanTrait};
    use cmp::min;
    use integer::{BoundedU256, U256Zeroable, u256_safe_divmod};
    use option::OptionTrait;
    use starknet::{get_block_timestamp, get_caller_address};
    use starknet::contract_address::{ContractAddress, ContractAddressZeroable};
    use traits::{Into, TryInto};
    use zeroable::Zeroable;

    use aura::core::roles::ShrineRoles;

    use aura::interfaces::IERC20::IERC20;
    use aura::interfaces::IShrine::IShrine;
    use aura::utils::access_control::{AccessControl, IAccessControl};
    use aura::utils::exp::{exp, neg_exp};
    //use aura::utils::storage_access;
    use aura::utils::types::{
        ExceptionalYangRedistribution, Trove, YangBalance, YangRedistribution, YangSuspensionStatus
    };
    use aura::utils::wadray;
    use aura::utils::wadray::{
        BoundedRay, Ray, RayZeroable, RAY_ONE, RAY_PERCENT, Wad, WadZeroable, WAD_DECIMALS, WAD_ONE,
        WAD_SCALE
    };

    //
    // Constants
    //

    // Initial multiplier value to ensure `get_recent_multiplier_from` terminates - (ray): RAY_ONE
    const INITIAL_MULTIPLIER: u128 = 1000000000000000000000000000;
    const MAX_MULTIPLIER: u128 = 3000000000000000000000000000; // Max of 3x (ray): 3 * RAY_ONE

    const MAX_THRESHOLD: u128 = 1000000000000000000000000000; // (ray): RAY_ONE

    // If a yang is deemed risky, it can be marked as suspended. During the
    // SUSPENSION_GRACE_PERIOD, this decision can be reverted and the yang's status
    // can be changed back to normal. If this does not happen, the yang is
    // suspended permanently, i.e. can't be used in the system ever again.
    // The start of a Yang's suspension period is tracked in `yang_suspension`
    const SUSPENSION_GRACE_PERIOD: u64 =
        consteval_int!((182 * 24 + 12) * 60 * 60); // 182.5 days, half a year, in seconds

    // Length of a time interval in seconds
    const TIME_INTERVAL: u64 = consteval_int!(30 * 60); // 30 minutes * 60 seconds per minute
    const TIME_INTERVAL_DIV_YEAR: u128 =
        57077625570776; // 1 / (48 30-minute intervals per day) / (365 days per year) = 0.000057077625 (wad)

    // Threshold for rounding remaining debt during redistribution (wad): 10**9
    const ROUNDING_THRESHOLD: u128 = 1000000000;

    // Maximum interest rate a yang can have (ray): RAY_ONE
    const MAX_YANG_RATE: u128 = 100000000000000000000000000;

    // Flag for setting the yang's new base rate to its previous base rate in `update_rates`
    // (ray): MAX_YANG_RATE + 1
    const USE_PREV_BASE_RATE: u128 = 1000000000000000000000000001;

    // Forge fee function parameters
    const FORGE_FEE_A: u128 = 92103403719761827360719658187; // 92.103403719761827360719658187 (ray)
    const FORGE_FEE_B: u128 = 55000000000000000; // 0.055 (wad)
    // The lowest yin spot price where the forge fee will still be zero
    const MIN_ZERO_FEE_YIN_PRICE: u128 = 995000000000000000; // 0.995 (wad)
    // The maximum forge fee as a percentage of forge amount
    const FORGE_FEE_CAP_PCT: u128 = 4000000000000000000; // 400% or 4 (wad)
    // The maximum deviation before `FORGE_FEE_CAP_PCT` is reached
    const FORGE_FEE_CAP_PRICE: u128 = 929900000000000000; // 0.9299 (wad)

    // Convenience constant for upward iteration of yangs
    const START_YANG_IDX: u32 = 1;

    #[storage]
    struct Storage {
        // A trove can forge debt up to its threshold depending on the yangs deposited.
        // (trove_id) -> (Trove)
        troves: LegacyMap::<u64, Trove>,
        // Stores the amount of the "yin" (synthetic) each user owns.
        // (user_address) -> (Yin)
        yin: LegacyMap::<ContractAddress, Wad>,
        // Stores information about the total supply for each yang
        // (yang_id) -> (Total Supply)
        yang_total: LegacyMap::<u32, Wad>,
        // Stores information about the initial yang amount minted to the system
        initial_yang_amts: LegacyMap::<u32, Wad>,
        // Number of collateral types accepted by the system.
        // The return value is also the ID of the last added collateral.
        yangs_count: u32,
        // Mapping from yang ContractAddress to yang ID.
        // Yang ID starts at 1.
        // (yang_address) -> (yang_id)
        yang_ids: LegacyMap::<ContractAddress, u32>,
        // Keeps track of how much of each yang has been deposited into each Trove - Wad
        // (yang_id, trove_id) -> (Amount Deposited)
        deposits: LegacyMap::<(u32, u64), Wad>,
        // Total amount of debt accrued
        total_debt: Wad,
        // Total amount of synthetic forged
        total_yin: Wad,
        // Keeps track of the price history of each Yang
        // Stores both the actual price and the cumulative price of
        // the yang at each time interval, both as Wads.
        // - interval: timestamp divided by TIME_INTERVAL.
        // (yang_id, interval) -> (price, cumulative_price)
        yang_prices: LegacyMap::<(u32, u64), (Wad, Wad)>,
        // Spot price of yin
        yin_spot_price: Wad,
        // Maximum amount of debt that can exist at any given time
        debt_ceiling: Wad,
        // Global interest rate multiplier
        // stores both the actual multiplier, and the cumulative multiplier of
        // the yang at each time interval, both as Rays
        // (interval) -> (multiplier, cumulative_multiplier)
        multiplier: LegacyMap::<u64, (Ray, Ray)>,
        // Keeps track of the most recent rates index.
        // Rate era starts at 1.
        // Each index is associated with an update to the interest rates of all yangs.
        rates_latest_era: u64,
        // Keeps track of the interval at which the rate update at `era` was made.
        // (era) -> (interval)
        rates_intervals: LegacyMap::<u64, u64>,
        // Keeps track of the interest rate of each yang at each era
        // (yang_id, era) -> (Interest Rate)
        yang_rates: LegacyMap::<(u32, u64), Ray>,
        // Keeps track of when a yang was suspended
        // 0 means it is not suspended
        // (yang_id) -> (suspension timestamp)
        yang_suspension: LegacyMap::<u32, u64>,
        // Liquidation threshold per yang (as LTV) - Ray
        // NOTE: don't read the value directly, instead use `get_yang_threshold_internal`
        //       because a yang might be suspended; the function will return the correct
        //       threshold value under all circumstances
        // (yang_id) -> (Liquidation Threshold)
        thresholds: LegacyMap::<u32, Ray>,
        // Keeps track of how many redistributions have occurred
        redistributions_count: u32,
        // Last redistribution accounted for a trove
        // (trove_id) -> (Last Redistribution ID)
        trove_redistribution_id: LegacyMap::<u64, u32>,
        // Keeps track of whether the redistribution involves at least one yang that
        // no other troves has deposited.
        // (redistribution_id) -> (Is exceptional redistribution)
        is_exceptional_redistribution: LegacyMap::<u32, bool>,
        // Mapping of yang ID and redistribution ID to
        // 1. amount of debt in Wad to be redistributed to each Wad unit of yang
        // 2. amount of debt to be added to the next redistribution to calculate (1)
        // (yang_id, redistribution_id) -> YangRedistribution{debt_per_wad, debt_to_add_to_next}
        yang_redistributions: LegacyMap::<(u32, u32), YangRedistribution>,
        // Mapping of recipient yang ID, redistribution ID and redistributed yang ID to
        // 1. amount of redistributed yang per Wad unit of recipient yang
        // 2. amount of debt per Wad unit of recipient yang
        yang_to_yang_redistribution: LegacyMap::<(u32, u32, u32), ExceptionalYangRedistribution>,
        // Keeps track of whether shrine is live or killed
        is_live: bool,
        // Yin storage
        yin_name: felt252,
        yin_symbol: felt252,
        yin_decimals: u8,
        // Mapping of user's yin allowance for another user
        // (user_address, spender_address) -> (Allowance)
        yin_allowances: LegacyMap::<(ContractAddress, ContractAddress), u256>,
    }

    //
    // Events
    //

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        YangAdded: YangAdded,
        YangTotalUpdated: YangTotalUpdated,
        DebtTotalUpdated: DebtTotalUpdated,
        YangsCountUpdated: YangsCountUpdated,
        MultiplierUpdated: MultiplierUpdated,
        YangRatesUpdated: YangRatesUpdated,
        ThresholdUpdated: ThresholdUpdated,
        ForgeFeePaid: ForgeFeePaid,
        TroveUpdated: TroveUpdated,
        TroveRedistributed: TroveRedistributed,
        DepositUpdated: DepositUpdated,
        YangPriceUpdated: YangPriceUpdated,
        YinPriceUpdated: YinPriceUpdated,
        DebtCeilingUpdated: DebtCeilingUpdated,
        Killed: Killed,
        Transfer: Transfer,
        Approval: Approval,
    }

    #[derive(Drop, starknet::Event)]
    struct YangAdded {
        #[key]
        yang: ContractAddress,
        yang_id: u32,
        start_price: Wad,
        initial_rate: Ray
    }

    #[derive(Drop, starknet::Event)]
    struct YangTotalUpdated {
        #[key]
        yang: ContractAddress,
        total: Wad
    }

    #[derive(Drop, starknet::Event)]
    struct DebtTotalUpdated {
        total: Wad
    }

    #[derive(Drop, starknet::Event)]
    struct YangsCountUpdated {
        count: u32
    }

    #[derive(Drop, starknet::Event)]
    struct MultiplierUpdated {
        multiplier: Ray,
        cumulative_multiplier: Ray,
        #[key]
        interval: u64
    }

    #[derive(Drop, starknet::Event)]
    struct YangRatesUpdated {
        #[key]
        new_rate_idx: u64,
        current_interval: u64,
        yangs: Span<ContractAddress>,
        new_rates: Span<Ray>
    }

    #[derive(Drop, starknet::Event)]
    struct ThresholdUpdated {
        #[key]
        yang: ContractAddress,
        threshold: Ray
    }

    #[derive(Drop, starknet::Event)]
    struct ForgeFeePaid {
        #[key]
        trove_id: u64,
        fee: Wad,
        fee_pct: Wad
    }

    #[derive(Drop, starknet::Event)]
    struct TroveUpdated {
        #[key]
        trove_id: u64,
        trove: Trove
    }

    #[derive(Drop, starknet::Event)]
    struct TroveRedistributed {
        #[key]
        redistribution_id: u32,
        #[key]
        trove_id: u64,
        debt: Wad
    }

    #[derive(Drop, starknet::Event)]
    struct DepositUpdated {
        #[key]
        yang: ContractAddress,
        #[key]
        trove_id: u64,
        amount: Wad
    }

    #[derive(Drop, starknet::Event)]
    struct YangPriceUpdated {
        #[key]
        yang: ContractAddress,
        price: Wad,
        cumulative_price: Wad,
        #[key]
        interval: u64
    }

    #[derive(Drop, starknet::Event)]
    struct YinPriceUpdated {
        old_price: Wad,
        new_price: Wad
    }

    #[derive(Drop, starknet::Event)]
    struct DebtCeilingUpdated {
        ceiling: Wad
    }

    #[derive(Drop, starknet::Event)]
    struct Killed {}

    // ERC20 events

    #[derive(Drop, starknet::Event)]
    struct Transfer {
        #[key]
        from: ContractAddress,
        #[key]
        to: ContractAddress,
        value: u256
    }

    #[derive(Drop, starknet::Event)]
    struct Approval {
        #[key]
        owner: ContractAddress,
        #[key]
        spender: ContractAddress,
        value: u256
    }

    //
    // Constructor
    //

    #[constructor]
    fn constructor(
        ref self: ContractState, admin: ContractAddress, name: felt252, symbol: felt252
    ) {
        AccessControl::initializer(admin);

        // Grant admin permission
        AccessControl::grant_role_internal(ShrineRoles::default_admin_role(), admin);

        self.is_live.write(true);

        // Seeding initial multiplier to the previous interval to ensure `get_recent_multiplier_from` terminates
        // otherwise, the next multiplier update will run into an endless loop of `get_recent_multiplier_from`
        // since it wouldn't find the initial multiplier
        let prev_interval: u64 = now() - 1;
        let init_multiplier: Ray = INITIAL_MULTIPLIER.into();
        self.multiplier.write(prev_interval, (init_multiplier, init_multiplier));

        // Setting initial rate era to 1
        self.rates_latest_era.write(1);

        // Setting initial yin spot price to 1
        self.yin_spot_price.write(WAD_ONE.into());

        // Emit event
        self
            .emit(
                MultiplierUpdated {
                    multiplier: init_multiplier,
                    cumulative_multiplier: init_multiplier,
                    interval: prev_interval
                }
            );

        // ERC20
        self.yin_name.write(name);
        self.yin_symbol.write(symbol);
        self.yin_decimals.write(WAD_DECIMALS);
    }

    //
    // Internal view functions
    // 

    #[inline(always)]
    fn now() -> u64 {
        starknet::get_block_timestamp() / TIME_INTERVAL
    }

    //
    // Public ERC20 functions
    //

    #[external(v0)]
    impl IERC20Impl of IERC20<ContractState> {
        // ERC20 getters
        fn name(self: @ContractState) -> felt252 {
            self.yin_name.read()
        }

        fn symbol(self: @ContractState) -> felt252 {
            self.yin_symbol.read()
        }

        fn decimals(self: @ContractState) -> u8 {
            self.yin_decimals.read()
        }

        fn total_supply(self: @ContractState) -> u256 {
            self.total_yin.read().val.into()
        }

        fn balance_of(self: @ContractState, account: ContractAddress) -> u256 {
            self.yin.read(account).val.into()
        }

        fn allowance(
            self: @ContractState, owner: ContractAddress, spender: ContractAddress
        ) -> u256 {
            self.yin_allowances.read((owner, spender))
        }

        // ERC20 public functions
        fn transfer(ref self: ContractState, recipient: ContractAddress, amount: u256) -> bool {
            self.transfer_internal(get_caller_address(), recipient, amount);
            true
        }

        fn transfer_from(
            ref self: ContractState,
            sender: ContractAddress,
            recipient: ContractAddress,
            amount: u256
        ) -> bool {
            self.spend_allowance_internal(sender, get_caller_address(), amount);
            self.transfer_internal(sender, recipient, amount);
            true
        }

        fn approve(ref self: ContractState, spender: ContractAddress, amount: u256) -> bool {
            self.approve_internal(get_caller_address(), spender, amount);
            true
        }
    }

    //
    // Internal ERC20 functions
    //

    #[generate_trait]
    impl ERC20InternalFunctions of ERC20InternalTrait {
        fn transfer_internal(
            ref self: ContractState,
            sender: ContractAddress,
            recipient: ContractAddress,
            amount: u256
        ) {
            assert(recipient.is_non_zero(), 'SH: No transfer to 0 address');

            let amount_wad: Wad = Wad { val: amount.try_into().unwrap() };

            // Transferring the Yin
            self.yin.write(sender, self.yin.read(sender) - amount_wad);
            self.yin.write(recipient, self.yin.read(recipient) + amount_wad);

            self.emit(Transfer { from: sender, to: recipient, value: amount });
        }

        fn approve_internal(
            ref self: ContractState, owner: ContractAddress, spender: ContractAddress, amount: u256
        ) {
            assert(spender.is_non_zero(), 'SH: No approval of 0 address');
            assert(owner.is_non_zero(), 'SH: No approval for 0 address');

            self.yin_allowances.write((owner, spender), amount);

            self.emit(Approval { owner: owner, spender: spender, value: amount });
        }

        fn spend_allowance_internal(
            ref self: ContractState, owner: ContractAddress, spender: ContractAddress, amount: u256
        ) {
            let current_allowance: u256 = self.yin_allowances.read((owner, spender));

            // if current_allowance is not set to the maximum u256, then
            // subtract `amount` from spender's allowance.
            if current_allowance != BoundedU256::max() {
                self.approve_internal(owner, spender, current_allowance - amount);
            }
        }
    }

    //
    // Public AccessControl functions
    //

    #[external(v0)]
    impl IAccessControlImpl of IAccessControl<ContractState> {
        fn get_roles(self: @ContractState, account: ContractAddress) -> u128 {
            AccessControl::get_roles(account)
        }

        fn has_role(self: @ContractState, role: u128, account: ContractAddress) -> bool {
            AccessControl::has_role(role, account)
        }

        fn get_admin(self: @ContractState) -> ContractAddress {
            AccessControl::get_admin()
        }

        fn get_pending_admin(self: @ContractState) -> ContractAddress {
            AccessControl::get_pending_admin()
        }

        fn grant_role(ref self: ContractState, role: u128, account: ContractAddress) {
            AccessControl::grant_role(role, account);
        }

        fn revoke_role(ref self: ContractState, role: u128, account: ContractAddress) {
            AccessControl::revoke_role(role, account);
        }

        fn renounce_role(ref self: ContractState, role: u128) {
            AccessControl::renounce_role(role);
        }

        fn set_pending_admin(ref self: ContractState, new_admin: ContractAddress) {
            AccessControl::set_pending_admin(new_admin);
        }

        fn accept_admin(ref self: ContractState) {
            AccessControl::accept_admin();
        }
    }
}
