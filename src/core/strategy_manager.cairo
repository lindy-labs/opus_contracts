#[starknet::contract]
mod StrategyManager {
    use cmp::min;
    use starknet::{ContractAddress, get_caller_address, get_contract_address};

    use opus::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use opus::interfaces::IStabilizer::{
        IStabilizerDispatcher, IStabilizerDispatcherTrait, IStrategyManager
    };

    #[storage]
    struct Storage {
        stabilizer: IStabilizerDispatcher,
        deployed_amount: u128,
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
        // Getters
        //

        fn get_deployed_amount(self: @ContractState) -> u128 {
            self.deployed_amount.read()
        }

        //
        // Core functions
        //

        fn execute(ref self: ContractState, amount: u128) {
            let stabilizer: IStabilizerDispatcher = self.stabilizer.read();
            assert(get_caller_address() == stabilizer.contract_address, 'SM: Only stabilizer');

            let deployed_amount: u128 = self.deployed_amount.read();
            let updated_deployed_amount: u128 = deployed_amount + amount;
            self.deployed_amount.write(updated_deployed_amount);
        }

        fn unwind(ref self: ContractState, amount: u128) {
            let stabilizer: IStabilizerDispatcher = self.stabilizer.read();
            assert(get_caller_address() == stabilizer.contract_address, 'SM: Only stabilizer');

            let deployed_amount: u128 = self.deployed_amount.read();
            assert(deployed_amount >= amount, 'SM: Exceeds deployed amount');
            self.deployed_amount.write(self.deployed_amount.read() - amount);

            let asset: IERC20Dispatcher = IERC20Dispatcher {
                contract_address: stabilizer.get_asset()
            };

            // TODO: Convert back to asset
            let converted_asset_amt: u128 = amount;

            // Transfer any excess asset (actual amount after unwinding - original amount) 
            // to receiver
            let remainder_asset_amt: u128 = if converted_asset_amt > amount {
                let receiver: ContractAddress = stabilizer.get_receiver();

                let excess_asset_amt: u128 = converted_asset_amt - amount;
                asset.transfer(receiver, excess_asset_amt.into());

                converted_asset_amt - excess_asset_amt
            } else {
                converted_asset_amt
            };

            // Transfer remainder back to Stabilizer
            asset.transfer(stabilizer.contract_address, remainder_asset_amt.into());
        }
    }

    #[generate_trait]
    impl StrategyManagerHelpers of StrategyManagerHelpersTrait {}
}
