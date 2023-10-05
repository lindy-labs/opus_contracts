#[starknet::contract]
mod Stabilizer {
    use cmp::min;
    use integer::BoundedU128;
    use starknet::{ContractAddress, get_caller_address, get_contract_address};

    use opus::core::roles::StabilizerRoles;

    use opus::interfaces::IAbbot::{IAbbotDispatcher, IAbbotDispatcherTrait};
    use opus::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use opus::interfaces::ISentinel::{ISentinelDispatcher, ISentinelDispatcherTrait};
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::interfaces::IStabilizer::{
        IStabilizer, IStrategyManagerDispatcher, IStrategyManagerDispatcherTrait
    };
    use opus::types::{AssetBalance, Strategy};
    use opus::utils::access_control::{AccessControl, IAccessControl};
    use opus::utils::reentrancy_guard::ReentrancyGuard;
    use opus::utils::wadray;
    use opus::utils::wadray::{Ray, RayZeroable, RAY_ONE, Wad, WadZeroable, WAD_ONE};

    #[storage]
    struct Storage {
        shrine: IShrineDispatcher,
        sentinel: ISentinelDispatcher,
        abbot: IAbbotDispatcher,
        asset: IERC20Dispatcher,
        ceiling: u128,
        trove_id: u64,
        strategies_count: u8,
        strategy_id: LegacyMap::<ContractAddress, u8>,
        strategies: LegacyMap::<u8, Strategy>,
        receiver: ContractAddress,
        is_live: bool,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        admin: ContractAddress,
        shrine: ContractAddress,
        sentinel: ContractAddress,
        abbot: ContractAddress,
        asset: ContractAddress,
        receiver: ContractAddress,
        ceiling: u128
    ) {
        AccessControl::initializer(admin, Option::Some(StabilizerRoles::default_admin_role()));

        self.shrine.write(IShrineDispatcher { contract_address: shrine });
        self.sentinel.write(ISentinelDispatcher { contract_address: sentinel });
        self.abbot.write(IAbbotDispatcher { contract_address: abbot });
        self.asset.write(IERC20Dispatcher { contract_address: asset });

        self.set_receiver_helper(receiver);
        self.set_ceiling_helper(ceiling);
    // TODO: Initialize ERC-20 with stabilizer as the only minter

    }

    #[external(v0)]
    impl IStabilizerImpl of IStabilizer<ContractState> {
        //
        // Getters
        //
        fn get_asset(self: @ContractState) -> ContractAddress {
            self.asset.read().contract_address
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

        //
        // Setters
        //

        fn initialize(ref self: ContractState, gate: ContractAddress, asset_max: u128) {
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

            // TODO: Set max approval of dummy token in stabilizer for gate

            // Transfer 1 Wad of asset to stabilizer
            let success: bool = self
                .asset
                .read()
                .transfer_from(get_caller_address(), stabilizer, WAD_ONE.into());

            // Open trove with Abbot
            let trove_id: u64 = self
                .abbot
                .read()
                .open_trove(
                    array![AssetBalance { address: stabilizer, amount: WAD_ONE }].span(),
                    WadZeroable::zero(),
                    WadZeroable::zero(),
                );

            self.trove_id.write(trove_id);
        }

        fn set_ceiling(ref self: ContractState, ceiling: u128) {
            AccessControl::assert_has_role(StabilizerRoles::SET_CEILING);

            self.set_ceiling_helper(ceiling);
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

            self.assert_can_forge();

            let user: ContractAddress = get_caller_address();
            let stabilizer: ContractAddress = get_contract_address();

            // Transfer asset to Stabilizer
            let success: bool = self.asset.read().transfer_from(user, stabilizer, asset_amt.into());
            assert(success, 'ST: Asset transfer failed');

            // TODO: Mint equivalent `asset_amt` in dummy tokens to stabilizer

            let shrine: IShrineDispatcher = self.shrine.read();
            let trove_id: u64 = self.trove_id.read();

            // reentrancy guard is used as a precaution
            ReentrancyGuard::start();

            let yang_amt: Wad = self
                .sentinel
                .read()
                .enter(stabilizer, stabilizer, trove_id, asset_amt);
            shrine.deposit(stabilizer, trove_id, yang_amt);

            ReentrancyGuard::end();

            let yin_amt = yang_amt;
            shrine.forge(user, trove_id, yin_amt, Option::None);
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
                    }
                );
        }

        fn set_strategy_ceiling(ref self: ContractState, strategy_id: u8, ceiling: u128) {
            AccessControl::assert_has_role(StabilizerRoles::SET_STRATEGY_CEILING);

            let mut strategy: Strategy = self.strategies.read(strategy_id);
            let old_ceiling: u128 = strategy.ceiling;
            strategy.ceiling = ceiling;
            self.strategies.write(strategy_id, strategy);
        // TODO: emit event
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
        }

        fn unwind_strategy(ref self: ContractState, strategy_id: u8, amount: u128) {
            AccessControl::assert_has_role(StabilizerRoles::UNWIND_STRATEGY);

            let strategy: Strategy = self.strategies.read(strategy_id);

            strategy.manager.unwind(amount);
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
        }

        // Note that `amount` refers to the dummy token balance that a user would receive
        // via `Caretaker.reclaim`.
        fn claim(ref self: ContractState, amount: u128) {
            assert(self.is_live.read(), 'ST: Stabilizer is live');

            let user: ContractAddress = get_caller_address();
            // TODO: Calculate corresponding amount of asset: (amount / total_supply) * asset_balance
            //       Burn `amount` worth of dummy tokens

            let asset_amt: u128 = 0;
            let asset: IERC20Dispatcher = self.asset.read();
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

            // TODO: Get the deposited amount of dummy token in the trove, and calculate
            //       the corresponding amount of assets (deposited_amount / total_supply) * stabilizer_asset_balance
            let amount: u128 = 0;

            self.asset.read().transfer(recipient, amount.into());
        }
    }

    #[generate_trait]
    impl StabilizerHelpers of StabilizerHelpersTrait {
        #[inline(always)]
        fn assert_can_forge(
            self: @ContractState
        ) { // TODO: Assert total supply of dummy tokens is less than ceiling
        }

        fn set_ceiling_helper(ref self: ContractState, ceiling: u128) {
            let old_ceiling: u128 = self.ceiling.read();
            self.ceiling.write(ceiling);
        // TODO emit event
        }

        fn set_receiver_helper(ref self: ContractState, receiver: ContractAddress) {
            assert(receiver.is_non_zero(), 'SM: Zero address');
            let old_receiver: ContractAddress = self.receiver.read();
            self.receiver.write(receiver);
        // TODO emit event
        }
    }
// TODO: Include ERC-20 functions
// TODO: Include access control functions
}
