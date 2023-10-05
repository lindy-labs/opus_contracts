#[starknet::contract]
mod StrategyManager {
    use starknet::{ContractAddress, get_caller_address, get_contract_address};

    use opus::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use opus::interfaces::ITransmuter::{
        ITransmuterDispatcher, ITransmuterDispatcherTrait, IStrategyManager
    };

    #[storage]
    struct Storage {
        transmuter: ITransmuterDispatcher,
    // TODO: To be customized according to strategy, e.g. LP tokens
    // strategy_token: IERC20Dispatcher
    }

    #[constructor]
    fn constructor(ref self: ContractState, transmuter: ContractAddress,) {
        self.transmuter.write(ITransmuterDispatcher { contract_address: transmuter });
    }

    #[external(v0)]
    impl IStrategyManagerImpl of IStrategyManager<ContractState> {
        //
        // Core functions
        //

        fn execute(ref self: ContractState, execute_amt: u128) {
            let transmuter: ITransmuterDispatcher = self.transmuter.read();
            assert(get_caller_address() == transmuter.contract_address, 'SM: Only transmuter');
        // TODO: Do stuff
        }

        fn unwind(ref self: ContractState, deployed_amt: u128, unwind_amt: u128) {
            let transmuter: ITransmuterDispatcher = self.transmuter.read();
            assert(get_caller_address() == transmuter.contract_address, 'SM: Only transmuter');

            let asset: IERC20Dispatcher = IERC20Dispatcher {
                contract_address: transmuter.get_asset()
            };

            // TODO: Do stuff
            //       For example, assuming this is a CASH/DAI LP strategy, withdraw
            //       (unwind_amt / deployed_amt) * LP token balance of manager, and
            //       transfer the DAI to Transmuter and excess to the receiver.

            let manager: ContractAddress = get_contract_address();
            let updated_amt: u128 = asset.balance_of(manager).try_into().unwrap();

            // Transfer any excess asset (actual amount after unwinding - original amount) 
            // to receiver
            let unwind_amt_for_transmuter: u128 = if updated_amt > unwind_amt {
                let receiver: ContractAddress = transmuter.get_receiver();

                let excess_asset_amt: u128 = updated_amt - unwind_amt;
                asset.transfer(receiver, excess_asset_amt.into());

                updated_amt - excess_asset_amt
            } else {
                updated_amt
            };

            // Transfer remainder back to Transmuter
            asset.transfer(transmuter.contract_address, unwind_amt_for_transmuter.into());
        }
    }

    #[generate_trait]
    impl StrategyManagerHelpers of StrategyManagerHelpersTrait {}
}
