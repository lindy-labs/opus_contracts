#[starknet::contract]
mod Stabilizer {
    use cmp::min;
    use integer::{BoundedU128, BoundedU256};
    use starknet::{ContractAddress, get_caller_address, get_contract_address};
    use starknet::contract_address::ContractAddressZeroable;

    use opus::core::roles::StabilizerRoles;

    use opus::interfaces::IAbbot::{IAbbotDispatcher, IAbbotDispatcherTrait};
    use opus::interfaces::IERC20::{IERC20, IERC20Dispatcher, IERC20DispatcherTrait};
    use opus::interfaces::ISentinel::{ISentinelDispatcher, ISentinelDispatcherTrait};
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::interfaces::IStabilizer::{
        IStabilizer, IStrategyManagerDispatcher, IStrategyManagerDispatcherTrait
    };
    use opus::types::{AssetBalance, Strategy};
    use opus::utils::access_control::{AccessControl, IAccessControl};
    use opus::utils::reentrancy_guard::ReentrancyGuard;
    use opus::utils::wadray;
    use opus::utils::wadray::{Ray, RayZeroable, RAY_ONE, Wad, WadZeroable, WAD_DECIMALS, WAD_ONE};

    //
    // Constants
    //

    // Upper bound of the maximum amount of yin that can be minted via this Stabilizer as a 
    // percentage of total yin supply: 10% (Ray)
    const PERCENTAGE_CAP_UPPER_BOUND: u128 = 100000000000000000000000000;

    // Note that the debt ceiling for a Stabilizer is enforced via the `yang_asset_max`
    // for the Stabilizer's dummy token in Sentinel. Therefore, any changes to the 
    // debt ceiling can be made via `Sentinel.set_yang_asset_max`.
    #[storage]
    struct Storage {
        shrine: IShrineDispatcher,
        sentinel: ISentinelDispatcher,
        asset: IERC20Dispatcher,
        trove_id: u64,
        percentage_cap: Ray,
        is_live: bool,
        // strategies
        strategies_count: u8,
        strategy_id: LegacyMap::<ContractAddress, u8>,
        strategies: LegacyMap::<u8, Strategy>,
        receiver: ContractAddress,
        // ERC-20
        name: felt252,
        symbol: felt252,
        total_supply: u256,
        balances: LegacyMap::<ContractAddress, u256>,
        allowances: LegacyMap::<(ContractAddress, ContractAddress), u256>,
    }

    //
    // Events
    //

    #[event]
    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    enum Event {
        Initialized: Initialized,
        Killed: Killed,
        PercentageCapUpdated: PercentageCapUpdated,
        Swap: Swap,
        ReceiverUpdated: ReceiverUpdated,
        StrategyAdded: StrategyAdded,
        StrategyCeilingUpdated: StrategyCeilingUpdated,
        ExecuteStrategy: ExecuteStrategy,
        UnwindStrategy: UnwindStrategy,
        // ERC-20 events
        Transfer: Transfer,
        Approval: Approval,
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct Initialized {
        trove_id: u64
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct Killed {}

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct PercentageCapUpdated {
        cap: Ray
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct Swap {
        #[key]
        user: ContractAddress,
        asset_amt: u128,
        yin_amt: Wad
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct ReceiverUpdated {
        old_receiver: ContractAddress,
        new_receiver: ContractAddress
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct StrategyAdded {
        #[key]
        strategy_id: u8,
        manager: ContractAddress,
        ceiling: u128
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct StrategyCeilingUpdated {
        #[key]
        strategy_id: u8,
        old_ceiling: u128,
        new_ceiling: u128
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct ExecuteStrategy {
        #[key]
        strategy_id: u8,
        amount: u128
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct UnwindStrategy {
        #[key]
        strategy_id: u8,
        amount: u128
    }

    // ERC-20 events

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct Transfer {
        #[key]
        from: ContractAddress,
        #[key]
        to: ContractAddress,
        value: u256
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct Approval {
        #[key]
        owner: ContractAddress,
        #[key]
        spender: ContractAddress,
        value: u256
    }

    // Constructor

    #[constructor]
    fn constructor(
        ref self: ContractState,
        admin: ContractAddress,
        shrine: ContractAddress,
        sentinel: ContractAddress,
        asset: ContractAddress,
        receiver: ContractAddress,
        percentage_cap: Ray,
        name: felt252,
        symbol: felt252
    ) {
        AccessControl::initializer(admin, Option::Some(StabilizerRoles::default_admin_role()));

        self.shrine.write(IShrineDispatcher { contract_address: shrine });
        self.sentinel.write(ISentinelDispatcher { contract_address: sentinel });
        self.asset.write(IERC20Dispatcher { contract_address: asset });

        self.set_receiver_helper(receiver);
        self.set_percentage_cap_helper(percentage_cap);

        self.ERC20_initialize(name, symbol);
    }

    #[external(v0)]
    impl IStabilizerImpl of IStabilizer<ContractState> {
        //
        // Getters
        //
        fn get_asset(self: @ContractState) -> ContractAddress {
            self.asset.read().contract_address
        }

        fn get_trove_id(self: @ContractState) -> u64 {
            self.trove_id.read()
        }

        fn get_percentage_cap(self: @ContractState) -> Ray {
            self.percentage_cap.read()
        }

        fn get_strategies_count(self: @ContractState) -> u8 {
            self.strategies_count.read()
        }

        fn get_strategy(self: @ContractState, strategy_id: u8) -> Strategy {
            self.strategies.read(strategy_id)
        }

        fn get_receiver(self: @ContractState) -> ContractAddress {
            self.receiver.read()
        }

        fn get_live(self: @ContractState) -> bool {
            self.is_live.read()
        }

        //
        // Setters
        //

        fn initialize(
            ref self: ContractState, abbot: ContractAddress, gate: ContractAddress, asset_max: u128
        ) {
            AccessControl::assert_has_role(StabilizerRoles::INITIALIZE);

            let stabilizer: ContractAddress = get_contract_address();

            // Contract needs to be granted permission to call `sentinel.add_yang` beforehand
            self
                .sentinel
                .read()
                .add_yang(
                    stabilizer,
                    asset_max,
                    RAY_ONE.into(), // fixed at 100% threshold
                    WAD_ONE.into(), // fixed at 1 USD price
                    RayZeroable::zero(), // fixed at 0% base rate
                    gate,
                    // Since the dummy token will not be circulated except in the event of 
                    // global shutdown, the issue of first depositor front-running in Gate
                    // does not occur. Therefore, the initial yang amount can be set to zero. 
                    Option::Some(0)
                );

            // Set max approval of dummy token in stabilizer for gate
            self.approve_helper(stabilizer, gate, BoundedU256::max());

            // Transfer 1 Wad of asset to stabilizer
            let success: bool = self
                .asset
                .read()
                .transfer_from(get_caller_address(), stabilizer, WAD_ONE.into());

            // Open trove with Abbot
            let trove_id: u64 = IAbbotDispatcher { contract_address: abbot }
                .open_trove(
                    array![AssetBalance { address: stabilizer, amount: WAD_ONE }].span(),
                    WadZeroable::zero(),
                    WadZeroable::zero(),
                );

            self.trove_id.write(trove_id);

            self.emit(Initialized { trove_id });
        }

        fn set_percentage_cap(ref self: ContractState, cap: Ray) {
            AccessControl::assert_has_role(StabilizerRoles::SET_PERCENTAGE_CAP);

            self.set_percentage_cap_helper(cap);
        }

        fn set_receiver(ref self: ContractState, receiver: ContractAddress) {
            AccessControl::assert_has_role(StabilizerRoles::SET_RECEIVER);

            self.set_receiver_helper(receiver);
        }

        // 
        // Core functions
        //

        // Dummy tokens are minted 1 : 1 for asset, scaled to Wad precision.
        fn swap_asset_for_yin(ref self: ContractState, asset_amt: u128) {
            assert(self.trove_id.read().is_non_zero(), 'ST: Not initialized');

            let asset: IERC20Dispatcher = self.asset.read();
            let dummy_amt_to_mint: Wad = wadray::fixed_point_to_wad(asset_amt, asset.decimals());
            self.assert_can_swap(dummy_amt_to_mint);

            // reentrancy guard is used as a precaution
            ReentrancyGuard::start();

            let user: ContractAddress = get_caller_address();
            let stabilizer: ContractAddress = get_contract_address();

            // Transfer asset to Stabilizer
            let success: bool = asset.transfer_from(user, stabilizer, asset_amt.into());
            assert(success, 'ST: Asset transfer failed');

            // Mint equivalent `asset_amt` in dummy tokens to stabilizer
            self.mint(stabilizer, dummy_amt_to_mint.into());

            let shrine: IShrineDispatcher = self.shrine.read();
            let trove_id: u64 = self.trove_id.read();

            let yang_amt: Wad = self
                .sentinel
                .read()
                .enter(stabilizer, stabilizer, trove_id, dummy_amt_to_mint.val);
            shrine.deposit(stabilizer, trove_id, yang_amt);

            let yin_amt = yang_amt;
            shrine.forge(user, trove_id, yin_amt, Option::None);

            ReentrancyGuard::end();

            self.emit(Swap { user, asset_amt, yin_amt })
        }

        //
        // Strategy functions
        //

        fn add_strategy(ref self: ContractState, strategy_manager: ContractAddress, ceiling: u128) {
            AccessControl::assert_has_role(StabilizerRoles::ADD_STRATEGY);

            assert(strategy_manager.is_non_zero(), 'ST: Zero address');
            assert(self.strategy_id.read(strategy_manager).is_zero(), 'ST: Strategy already added');

            let strategy_id: u8 = self.strategies_count.read() + 1;
            self.strategies_count.write(strategy_id);
            self.strategy_id.write(strategy_manager, strategy_id);

            self
                .strategies
                .write(
                    strategy_id,
                    Strategy {
                        manager: IStrategyManagerDispatcher { contract_address: strategy_manager },
                        ceiling,
                    },
                );

            self.emit(StrategyAdded { strategy_id, manager: strategy_manager, ceiling });
        }

        fn set_strategy_ceiling(ref self: ContractState, strategy_id: u8, ceiling: u128) {
            AccessControl::assert_has_role(StabilizerRoles::SET_STRATEGY_CEILING);

            let mut strategy: Strategy = self.strategies.read(strategy_id);
            let old_ceiling: u128 = strategy.ceiling;
            strategy.ceiling = ceiling;
            self.strategies.write(strategy_id, strategy);

            self.emit(StrategyCeilingUpdated { strategy_id, old_ceiling, new_ceiling: ceiling });
        }

        fn execute_strategy(ref self: ContractState, strategy_id: u8, amount: u128) {
            AccessControl::assert_has_role(StabilizerRoles::EXECUTE_STRATEGY);

            let mut strategy: Strategy = self.strategies.read(strategy_id);

            let stabilizer: ContractAddress = get_contract_address();
            let asset: IERC20Dispatcher = self.asset.read();
            let balance: u128 = asset.balance_of(stabilizer).try_into().unwrap();
            let amount: u128 = min(amount, balance);

            let updated_deployed_amount = strategy.manager.get_deployed_amount() + amount;
            assert(updated_deployed_amount <= strategy.ceiling, 'ST: Strategy ceiling exceeded');

            asset.transfer(strategy.manager.contract_address, amount.into());
            strategy.manager.execute(amount);

            self.emit(ExecuteStrategy { strategy_id, amount });
        }

        fn unwind_strategy(ref self: ContractState, strategy_id: u8, amount: u128) {
            AccessControl::assert_has_role(StabilizerRoles::UNWIND_STRATEGY);

            let strategy: Strategy = self.strategies.read(strategy_id);

            strategy.manager.unwind(amount);

            self.emit(UnwindStrategy { strategy_id, amount });
        }

        //
        // Shutdown
        //

        // Loops through all strategies and unwinds each strategy
        fn kill(ref self: ContractState) {
            AccessControl::assert_has_role(StabilizerRoles::KILL);
            self.is_live.write(false);

            let strategies_count: u8 = self.strategies_count.read();
            let loop_end: u8 = 0;

            let mut strategy_id: u8 = strategies_count;
            loop {
                if strategy_id == loop_end {
                    break;
                }

                let strategy: Strategy = self.strategies.read(strategy_id);
                strategy.manager.unwind(BoundedU128::max());
            };

            self.emit(Killed {});
        }

        // Note that `amount` refers to the dummy token balance that a user would receive
        // via `Caretaker.reclaim`.
        fn claim(ref self: ContractState, amount: Wad) {
            assert(self.is_live.read(), 'ST: Stabilizer is live');

            let stabilizer: ContractAddress = get_contract_address();
            let user: ContractAddress = get_caller_address();

            let asset: IERC20Dispatcher = self.asset.read();
            let asset_balance: u256 = asset.balance_of(stabilizer);
            let total_supply: Wad = self.total_supply.read().try_into().unwrap();
            let asset_amt: Wad = (amount / total_supply) * asset_balance.try_into().unwrap();

            self.burn(user, amount.into());
            asset.transfer(user, asset_amt.into());
        }

        // After `Caretaker.shut` is triggered, there will be some amount of dummy tokens
        // remaining in the trove. For example, if 70% of the Shrine's collateral is transferred to the 
        // Caretaker to back circulating yin, then the Stabilizer's trove will have 30% of dummy tokens 
        // remaining in its trove that corresponds to 30% of the asset's value in the Stabilizer after
        // all strategies have been unwound. This function sends the amount of assets corresponding to this
        // remainder dummy tokens to a prescribed address.
        fn extract(ref self: ContractState, recipient: ContractAddress) {
            assert(self.is_live.read(), 'ST: Stabilizer is live');

            AccessControl::assert_has_role(StabilizerRoles::EXTRACT);

            let stabilizer: ContractAddress = get_contract_address();
            let shrine: IShrineDispatcher = self.shrine.read();
            let asset: IERC20Dispatcher = self.asset.read();

            let deposited_amt: Wad = shrine.get_deposit(stabilizer, self.trove_id.read());
            let total_supply: Wad = self.total_supply.read().try_into().unwrap();
            let asset_balance: u256 = asset.balance_of(stabilizer);
            let extract_amt: Wad = (deposited_amt / total_supply)
                * asset_balance.try_into().unwrap();

            self.asset.read().transfer(recipient, extract_amt.into());
        }
    }

    #[generate_trait]
    impl StabilizerHelpers of StabilizerHelpersTrait {
        // Note that the debt ceiling for a Stabilizer is already enforced via the `yang_asset_max`
        // for the Stabilizer's dummy token in Sentinel.
        #[inline(always)]
        fn assert_can_swap(self: @ContractState, amt_to_mint: Wad) {
            let yin_price_ge_peg: bool = self.shrine.read().get_yin_spot_price() >= WAD_ONE.into();

            let cap: Wad = wadray::rmul_wr(
                self.shrine.read().get_total_yin(), self.percentage_cap.read()
            );
            let minted: Wad = self.total_supply.read().try_into().unwrap();
            let is_lt_cap: bool = minted + amt_to_mint <= cap;

            assert(yin_price_ge_peg && is_lt_cap, 'ST: Temporarily paused');
        }

        fn set_receiver_helper(ref self: ContractState, receiver: ContractAddress) {
            assert(receiver.is_non_zero(), 'SM: Zero address');
            let old_receiver: ContractAddress = self.receiver.read();
            self.receiver.write(receiver);

            self.emit(ReceiverUpdated { old_receiver, new_receiver: receiver });
        }

        fn set_percentage_cap_helper(ref self: ContractState, cap: Ray) {
            assert(cap <= PERCENTAGE_CAP_UPPER_BOUND.into(), 'SM: Exceeds upper bound of 10%');
            self.percentage_cap.write(cap);

            self.emit(PercentageCapUpdated { cap });
        }
    }

    #[external(v0)]
    impl IERC20Impl of IERC20<ContractState> {
        // ERC20 getters
        fn name(self: @ContractState) -> felt252 {
            self.name.read()
        }

        fn symbol(self: @ContractState) -> felt252 {
            self.symbol.read()
        }

        fn decimals(self: @ContractState) -> u8 {
            WAD_DECIMALS.try_into().unwrap()
        }

        fn total_supply(self: @ContractState) -> u256 {
            self.total_supply.read()
        }

        fn balance_of(self: @ContractState, account: ContractAddress) -> u256 {
            self.balances.read(account)
        }

        fn allowance(
            self: @ContractState, owner: ContractAddress, spender: ContractAddress
        ) -> u256 {
            self.allowances.read((owner, spender))
        }

        // ERC20 public functions
        fn transfer(ref self: ContractState, recipient: ContractAddress, amount: u256) -> bool {
            self.transfer_helper(get_caller_address(), recipient, amount);
            true
        }

        fn transfer_from(
            ref self: ContractState,
            sender: ContractAddress,
            recipient: ContractAddress,
            amount: u256
        ) -> bool {
            self.spend_allowance_helper(sender, get_caller_address(), amount);
            self.transfer_helper(sender, recipient, amount);
            true
        }

        fn approve(ref self: ContractState, spender: ContractAddress, amount: u256) -> bool {
            self.approve_helper(get_caller_address(), spender, amount);
            true
        }
    }

    //
    // Internal ERC20 functions
    //

    #[generate_trait]
    impl ERC20Helpers of ERC20HelpersTrait {
        fn ERC20_initialize(ref self: ContractState, name: felt252, symbol: felt252) {
            self.name.write(name);
            self.symbol.write(symbol);
        }

        fn mint(ref self: ContractState, recipient: ContractAddress, amount: u256) -> bool {
            self.total_supply.write(self.total_supply.read() + amount);
            self.balances.write(recipient, self.balances.read(recipient) + amount);
            self
                .emit(
                    Transfer { from: ContractAddressZeroable::zero(), to: recipient, value: amount }
                );
            true
        }

        fn burn(ref self: ContractState, account: ContractAddress, amount: u256) -> bool {
            self.total_supply.write(self.total_supply.read() - amount);
            self.balances.write(account, self.balances.read(account) - amount);
            self
                .emit(
                    Transfer { from: account, to: ContractAddressZeroable::zero(), value: amount }
                );
            true
        }

        fn transfer_helper(
            ref self: ContractState,
            sender: ContractAddress,
            recipient: ContractAddress,
            amount: u256
        ) {
            assert(recipient.is_non_zero(), 'SH: No transfer to 0 address');

            // Transferring the Yin
            let sender_balance: u256 = self.balances.read(sender);
            assert(sender_balance >= amount, 'SH: Insufficient yin balance');

            self.balances.write(sender, sender_balance - amount);
            self.balances.write(recipient, self.balances.read(recipient) + amount);

            self.emit(Transfer { from: sender, to: recipient, value: amount });
        }

        fn approve_helper(
            ref self: ContractState, owner: ContractAddress, spender: ContractAddress, amount: u256
        ) {
            assert(spender.is_non_zero(), 'SH: No approval of 0 address');
            assert(owner.is_non_zero(), 'SH: No approval for 0 address');

            self.allowances.write((owner, spender), amount);

            self.emit(Approval { owner, spender, value: amount });
        }

        fn spend_allowance_helper(
            ref self: ContractState, owner: ContractAddress, spender: ContractAddress, amount: u256
        ) {
            let current_allowance: u256 = self.allowances.read((owner, spender));

            // if current_allowance is not set to the maximum u256, then
            // subtract `amount` from spender's allowance.
            if current_allowance != BoundedU256::max() {
                assert(current_allowance >= amount, 'SH: Insufficient yin allowance');
                self.approve_helper(owner, spender, current_allowance - amount);
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
