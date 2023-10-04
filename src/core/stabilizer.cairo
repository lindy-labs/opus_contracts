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
        IStabilizer, IStabilizerStrategyDispatcher, IStabilizerStrategyDispatcherTrait
    };
    use opus::types::AssetBalance;
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
        trove_id: u64,
        strategies_count: u8,
        strategy_id: LegacyMap::<ContractAddress, u8>,
        strategies: LegacyMap::<u8, IStabilizerStrategyDispatcher>,
        is_live: bool,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        admin: ContractAddress,
        shrine: ContractAddress,
        sentinel: ContractAddress,
        abbot: ContractAddress,
        asset: ContractAddress
    ) {
        AccessControl::initializer(admin, Option::Some(StabilizerRoles::default_admin_role()));

        self.shrine.write(IShrineDispatcher { contract_address: shrine });
        self.sentinel.write(ISentinelDispatcher { contract_address: sentinel });
        self.abbot.write(IAbbotDispatcher { contract_address: abbot });
        self.asset.write(IERC20Dispatcher { contract_address: asset });
    // TODO: Initialize ERC-20 with stabilizer as the only minter

    }

    #[external(v0)]
    impl IStabilizerImpl of IStabilizer<ContractState> {
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

        fn add_strategy(ref self: ContractState, strategy: ContractAddress) {
            AccessControl::assert_has_role(StabilizerRoles::ADD_STRATEGY);

            assert(strategy.is_non_zero(), 'ST: Zero address');
            assert(self.strategy_id.read(strategy).is_zero(), 'ST: Strategy already added');

            let strategy_id: u8 = self.strategies_count.read() + 1;
            self.strategies_count.write(strategy_id);
            self.strategy_id.write(strategy, strategy_id);
            self
                .strategies
                .write(strategy_id, IStabilizerStrategyDispatcher { contract_address: strategy });
        }

        fn execute_strategy(ref self: ContractState, strategy: ContractAddress, amount: u128) {
            AccessControl::assert_has_role(StabilizerRoles::EXECUTE_STRATEGY);

            let strategy_id: u8 = self.strategy_id.read(strategy);
            assert(strategy_id.is_non_zero(), 'ST: Strategy not added');

            let stabilizer: ContractAddress = get_contract_address();
            let balance: u128 = self.asset.read().balance_of(stabilizer).try_into().unwrap();
            let amount: u128 = min(amount, balance);
            IStabilizerStrategyDispatcher { contract_address: strategy }.execute(amount);
        }

        fn unwind_strategy(ref self: ContractState, strategy: ContractAddress, amount: u128) {
            AccessControl::assert_has_role(StabilizerRoles::UNWIND_STRATEGY);

            let strategy_id: u8 = self.strategy_id.read(strategy);
            assert(strategy_id.is_non_zero(), 'ST: Strategy not added');

            IStabilizerStrategyDispatcher { contract_address: strategy }.unwind(amount);
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

                let strategy: IStabilizerStrategyDispatcher = self.strategies.read(strategy_id);
                strategy.unwind(BoundedU128::max());
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
        fn assert_can_forge(self: @ContractState) { // TODO: Check conditions for minting CASH
        }
    }
// TODO: Include ERC-20 functions
// TODO: Include access control functions
}
