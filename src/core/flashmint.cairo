//
//
//   Flash minting
//
//         |
//        / \
//       / _ \
//      |.o '.|
//      |'._.'|
//      |     |
//    ,'| LFG |`.
//   /  |  |  |  \
//   |,-'--|--'-.|
//
//

#[contract]
mod FlashMint {
    use option::OptionTrait;
    use starknet::ContractAddress;
    use traits::{Into, TryInto};

    use aura::interfaces::IFlashBorrower::{IFlashBorrowerDispatcher, IFlashBorrowerDispatcherTrait};
    use aura::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use aura::utils::reentrancy_guard::ReentrancyGuard;
    use aura::utils::u256_conversions::{U256TryIntoU128, U128IntoU256};
    use aura::utils::wadray::Wad;

    // The value of keccak256("ERC3156FlashBorrower.onFlashLoan") as per EIP3156
    // it is supposed to be returned from the onFlashLoan function by the receiver
    const ON_FLASH_MINT_SUCCESS: u256 =
        0x439148f0bbc682ca079e46d6e2c2f0c1e3b820f1a291b069d8882abf8cf18dd9_u256;

    // Percentage value of Yin's total supply that can be flash minted (wad)
    const FLASH_MINT_AMOUNT_PCT: u128 = 50000000000000000;

    struct Storage {
        shrine: IShrineDispatcher, 
    }

    #[event]
    fn FlashMint(
        initiator: ContractAddress, receiver: ContractAddress, token: ContractAddress, amount: u256
    ) {}

    #[constructor]
    fn constructor(shrine: ContractAddress) {
        shrine::write(IShrineDispatcher { contract_address: shrine });
    }

    //
    // View Functions
    //

    #[view]
    fn max_flash_loan(token: ContractAddress) -> u256 {
        let shrine: IShrineDispatcher = shrine::read();

        // Can only flash mint our own synthetic
        if token == shrine.contract_address {
            let supply: Wad = shrine.get_total_yin();
            return (supply * Wad { val: FLASH_MINT_AMOUNT_PCT }).val.into();
        }

        0_u256
    }

    #[view]
    fn flash_fee(token: ContractAddress, amount: u256) -> u256 {
        // as per EIP3156, if a token is not supported, this function must revert
        // and we only support flash minting of our own synthetic
        assert(shrine::read().contract_address == token, 'Unsupported token');

        0_u256
    }

    //
    // External Functions
    //

    #[external]
    fn flash_loan(
        receiver: ContractAddress, token: ContractAddress, amount: u256, calldata: Array<felt252>
    ) -> bool {
        // prevents looping which would lead to excessive minting
        // we only allow a FLASH_MINT_AMOUNT_PCT percentage of total
        // yin to be minted, as per spec
        ReentrancyGuard::start();

        assert(amount <= max_flash_loan(token), 'amount exceeds maximum');

        let shrine = shrine::read();

        let amount_wad = Wad { val: amount.try_into().unwrap() };

        shrine.inject(receiver, amount_wad);

        let initiator: ContractAddress = starknet::get_caller_address();

        let borrower_resp: u256 = IFlashBorrowerDispatcher {
            contract_address: receiver
        }.on_flash_loan(initiator, token, amount, 0_u256, calldata);

        assert(borrower_resp == ON_FLASH_MINT_SUCCESS, 'on_flash_loan callback failed');

        // This function in Shrine takes care of balance validation
        shrine.eject(receiver, amount_wad);

        FlashMint(initiator, receiver, token, amount);

        ReentrancyGuard::end();

        true
    }
}
