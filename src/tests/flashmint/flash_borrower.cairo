#[contract]
mod FlashBorrower {
    use array::SpanTrait;
    use option::OptionTrait;
    use starknet::{contract_address_const, get_contract_address, ContractAddress};

    use aura::core::flashmint::FlashMint::ON_FLASH_MINT_SUCCESS;

    use aura::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use aura::interfaces::IFlashMint::{IFlashMintDispatcher, IFlashMintDispatcherTrait};
    use aura::utils::serde;

    const VALID_USAGE: felt252 = 0;
    const ATTEMPT_TO_STEAL: felt252 = 1; 
    const ATTEMPT_TO_REENTER: felt252 = 2;

    struct Storage {
        flashmint: IFlashMintDispatcher,
    }

    #[constructor]
    fn constructor(flashmint: ContractAddress) {
        flashmint::write(IFlashMintDispatcher{contract_address: flashmint});
    }

    #[event]
    fn FlashLoancall_dataReceived(initiator: ContractAddress, token: ContractAddress, amount: u256, fee: u256, call_data: Span<felt252>) {}
    
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

        if action == VALID_USAGE {
            assert(IERC20Dispatcher{contract_address: token}.balance_of(get_contract_address()) == amount, 'FB: incorrect loan amount');
        } else if action == ATTEMPT_TO_STEAL {
            IERC20Dispatcher{contract_address: token}.transfer(contract_address_const::<0xbeef>(), amount);
        } else if action == ATTEMPT_TO_REENTER {
            flashmint::read().flash_loan(initiator, token, amount, call_data_copy);
        }

        // Emit event so tests can check that the function arguments are correct 
        FlashLoancall_dataReceived(initiator, token, amount, fee, call_data_copy);

        if should_return_correct {
            ON_FLASH_MINT_SUCCESS
        } else {
            0xbadbeef_u256
        }
    }
}
