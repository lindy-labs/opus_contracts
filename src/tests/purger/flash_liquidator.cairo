use starknet::ContractAddress;

use aura::interfaces::IGate::{IGateDispatcher, IGateDispatcherTrait};

#[starknet::interface]
trait IFlashLiquidator<TContractState> {
    fn flash_liquidate(
        ref self: TContractState,
        trove_id: u64,
        yangs: Span<ContractAddress>,
        gates: Span<IGateDispatcher>
    );
}

#[starknet::contract]
mod FlashLiquidator {
    use integer::BoundedInt;
    use starknet::{get_contract_address, ContractAddress};

    use aura::core::flashmint::FlashMint::ON_FLASH_MINT_SUCCESS;

    use aura::interfaces::IAbbot::{IAbbotDispatcher, IAbbotDispatcherTrait};
    use aura::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use aura::interfaces::IFlashBorrower::IFlashBorrower;
    use aura::interfaces::IFlashMint::{IFlashMintDispatcher, IFlashMintDispatcherTrait};
    use aura::interfaces::IGate::{IGateDispatcher, IGateDispatcherTrait};
    use aura::interfaces::IPurger::{IPurgerDispatcher, IPurgerDispatcherTrait};
    use aura::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use aura::types::AssetBalance;
    use aura::utils::wadray;
    use aura::utils::wadray::{Wad, WadZeroable};

    use aura::tests::absorber::utils::AbsorberUtils;
    use aura::tests::common;

    #[storage]
    struct Storage {
        shrine: IShrineDispatcher,
        abbot: IAbbotDispatcher,
        flashmint: IFlashMintDispatcher,
        purger: IPurgerDispatcher,
    }


    #[constructor]
    fn constructor(
        ref self: ContractState,
        shrine: ContractAddress,
        abbot: ContractAddress,
        flashmint: ContractAddress,
        purger: ContractAddress
    ) {
        self.shrine.write(IShrineDispatcher { contract_address: shrine });
        self.abbot.write(IAbbotDispatcher { contract_address: abbot });
        self.flashmint.write(IFlashMintDispatcher { contract_address: flashmint });
        self.purger.write(IPurgerDispatcher { contract_address: purger });
    }

    #[external(v0)]
    impl IFlashLiquidatorImpl of super::IFlashLiquidator<ContractState> {
        fn flash_liquidate(
            ref self: ContractState,
            trove_id: u64,
            mut yangs: Span<ContractAddress>,
            mut gates: Span<IGateDispatcher>
        ) {
            // Approve gate for tokens
            loop {
                match yangs.pop_front() {
                    Option::Some(yang) => {
                        let gate: IGateDispatcher = *gates.pop_front().unwrap();
                        let token = IERC20Dispatcher { contract_address: *yang };
                        token.approve(gate.contract_address, BoundedInt::max());
                    },
                    Option::None => { break; }
                };
            };

            let purger: IPurgerDispatcher = self.purger.read();
            let (_, max_close_amt) = purger.preview_liquidate(trove_id);
            let mut call_data: Array<felt252> = array![trove_id.into()];

            self
                .flashmint
                .read()
                .flash_loan(
                    get_contract_address(), // receiver
                    self.shrine.read().contract_address, // token
                    max_close_amt.into(), // amount
                    call_data.span()
                );
        }
    }

    #[external(v0)]
    impl IFlashBorrowerImpl of IFlashBorrower<ContractState> {
        fn on_flash_loan(
            ref self: ContractState,
            initiator: ContractAddress,
            token: ContractAddress,
            amount: u256,
            fee: u256,
            mut call_data: Span<felt252>
        ) -> u256 {
            let flash_liquidator: ContractAddress = get_contract_address();

            assert(
                IERC20Dispatcher { contract_address: token }.balance_of(flash_liquidator) == amount,
                'FL: incorrect loan amount'
            );

            let trove_id: u64 = (*call_data.pop_front().unwrap()).try_into().unwrap();
            let freed_assets: Span<AssetBalance> = self
                .purger
                .read()
                .liquidate(trove_id, amount.try_into().unwrap(), flash_liquidator);

            let mut provider_assets: Span<u128> = AbsorberUtils::provider_asset_amts();
            let mut updated_assets: Array<AssetBalance> = ArrayTrait::new();
            let mut freed_assets_copy = freed_assets;
            loop {
                match freed_assets_copy.pop_front() {
                    Option::Some(freed_asset) => {
                        updated_assets
                            .append(
                                AssetBalance {
                                    address: *freed_asset.address,
                                    amount: *freed_asset.amount
                                        + *provider_assets.pop_front().unwrap()
                                }
                            );
                    },
                    Option::None => { break; },
                };
            };

            // Open a trove with funded and freed assets, and mint the loan amount.
            // This should revert if the contract did not receive the freed assets
            // from the liquidation.
            self
                .abbot
                .read()
                .open_trove(updated_assets.span(), amount.try_into().unwrap(), WadZeroable::zero());

            ON_FLASH_MINT_SUCCESS
        }
    }
}
