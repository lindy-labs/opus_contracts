#[abi]
trait IFlashLiquidator {
    fn flash_liquidate(trove_id: u64);
}

#[contract]
mod FlashLiquidator {
    use array::{ArrayTrait, SpanTrait};
    use option::OptionTrait;
    use starknet::{contract_address_const, get_contract_address, ContractAddress};
    use traits::{Default, Into};

    use aura::core::flashmint::FlashMint::ON_FLASH_MINT_SUCCESS;
    use aura::interfaces::IAbbot::{IAbbotDispatcher, IAbbotDispatcherTrait};
    use aura::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use aura::interfaces::IFlashMint::{IFlashMintDispatcher, IFlashMintDispatcherTrait};
    use aura::interfaces::IPurger::{IPurgerDispatcher, IPurgerDispatcherTrait};
    use aura::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use aura::utils::serde;
    use aura::utils::wadray;
    use aura::utils::wadray::{Wad, WadZeroable};

    struct Storage {
        shrine: IShrineDispatcher,
        abbot: IAbbotDispatcher,
        flashmint: IFlashMintDispatcher,
        purger: IPurgerDispatcher,
    }

    #[constructor]
    fn constructor(shrine: ContractAddress, abbot: ContractAddress, flashmint: ContractAddress, purger: ContractAddress) {
        shrine::write(IShrineDispatcher { contract_address: shrine });
        abbot::write(IAbbotDispatcher { contract_address: abbot });
        flashmint::write(IFlashMintDispatcher { contract_address: flashmint });
        purger::write(IPurgerDispatcher { contract_address: purger });
    }

    #[event]
    fn FlashLoancall_dataReceived(initiator: ContractAddress, token: ContractAddress, amount: u256, fee: u256, call_data: Span<felt252>) {}

    #[external]
    fn flash_liquidate(trove_id: u64) {
        let purger: IPurgerDispatcher = purger::read();
        let max_close_amt: Wad = purger.get_max_liquidation_amount(trove_id);

        let flash_liquidator: ContractAddress = get_contract_address();
        let call_data: Array<felt252> = Default::default();
        call_data.append(trove_id.into());

        flashmint::read().flash_loan(
            get_contract_address(), // receiver
            shrine.contract_address, // token
            max_close_amt.into(), // amount
            call_data.span()
        };
    }

    #[external]
    fn on_flash_loan(
        initiator: ContractAddress,
        token: ContractAddress,
        amount: u256,
        fee: u256,
        mut call_data: Span<felt252>
    ) -> u256 {
        let call_data_copy = call_data;

        let should_return_correct: bool = *call_data.pop_front().unwrap() != 0;
        let action: felt252 = *call_data.pop_front().unwrap();

        assert(IERC20Dispatcher{contract_address: token}.balance_of(get_contract_address()) == amount, 'FB: incorrect loan amount');

        let trove_id: u64 = *call_data.pop_front().unwrap();

        let flash_liquidator: ContractAddress = get_contract_address();
        let (freed_assets, freed_asset_amts) = purger::read().liquidate(trove_id, amount.try_into().unwrap(), flash_liquidator);

        // Open a trove with freed assets
        abbot::read().open_trove(amount.into(), freed_assets, freed_asset_amts, WadZeroable::zero());

        ON_FLASH_MINT_SUCCESS
    }
}
