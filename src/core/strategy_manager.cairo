#[starknet::contract]
mod StrategyManager {
    use starknet::{ContractAddress, get_caller_address, get_contract_address};

    use opus::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use opus::interfaces::IStabilizer::{
        IStabilizerDispatcher, IStabilizerDispatcherTrait, IStrategyManager
    };

    #[storage]
    struct Storage {
        stabilizer: IStabilizerDispatcher,
    // TODO: To be customized according to strategy, e.g. LP tokens
    // strategy_token: IERC20Dispatcher
    }

    #[constructor]
    fn constructor(ref self: ContractState, stabilizer: ContractAddress,) {
        self.stabilizer.write(IStabilizerDispatcher { contract_address: stabilizer });
    }

    #[external(v0)]
    impl IStrategyManagerImpl of IStrategyManager<ContractState> {
        //
        // Core functions
        //

        fn execute(ref self: ContractState, execute_amt: u128) {
            let stabilizer: IStabilizerDispatcher = self.stabilizer.read();
            assert(get_caller_address() == stabilizer.contract_address, 'SM: Only stabilizer');
        // TODO: Do stuff
        }

        fn unwind(ref self: ContractState, deployed_amt: u128, unwind_amt: u128) {
            let stabilizer: IStabilizerDispatcher = self.stabilizer.read();
            assert(get_caller_address() == stabilizer.contract_address, 'SM: Only stabilizer');

            let asset: IERC20Dispatcher = IERC20Dispatcher {
                contract_address: stabilizer.get_asset()
            };

            // TODO: Do stuff
            //       For example, assuming this is a CASH/DAI LP strategy, withdraw
            //       (unwind_amt / deployed_amt) * LP token balance of manager, and
            //       transfer the DAI to Stabilizer and excess to the receiver.

            let manager: ContractAddress = get_contract_address();
            let updated_amt: u128 = asset.balance_of(manager).try_into().unwrap();

            // Transfer any excess asset (actual amount after unwinding - original amount) 
            // to receiver
            let unwind_amt_for_stabilizer: u128 = if updated_amt > unwind_amt {
                let receiver: ContractAddress = stabilizer.get_receiver();

                let excess_asset_amt: u128 = updated_amt - unwind_amt;
                asset.transfer(receiver, excess_asset_amt.into());

                updated_amt - excess_asset_amt
            } else {
                updated_amt
            };

            // Transfer remainder back to Stabilizer
            asset.transfer(stabilizer.contract_address, unwind_amt_for_stabilizer.into());
        }
    }

    #[generate_trait]
    impl StrategyManagerHelpers of StrategyManagerHelpersTrait {}
}
