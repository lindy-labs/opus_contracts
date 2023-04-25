#[contract]
mod FlashMint {
    use option::OptionTrait;
    use starknet::ContractAddress;
    use traits::Into;
    use traits::TryInto;


    use aura::interfaces::IERC20::IERC20Dispatcher;
    use aura::interfaces::IERC20::IERC20DispatcherTrait;
    use aura::interfaces::IFlashBorrower::IFlashBorrowerDispatcher;
    use aura::interfaces::IFlashBorrower::IFlashBorrowerDispatcherTrait;
    use aura::interfaces::IShrine::IShrineDispatcher;
    use aura::interfaces::IShrine::IShrineDispatcherTrait;
    use aura::utils::u256_conversions::U256TryIntoU128;
    use aura::utils::wadray::Wad;

    // The value of keccak256("ERC3156FlashBorrower.onFlashLoan") as per EIP3156
    // it is supposed to be returned from the onFlashLoan function by the receiver
    // the raw value is 0x439148f0bbc682ca079e46d6e2c2f0c1e3b820f1a291b069d8882abf8cf18dd9
    // and here it's split into Uint256 parts
    const ON_FLASH_MINT_SUCCESS_LOW: u128 = 302690805846553493147886643436372200921;
    const ON_FLASH_MINT_SUCCESS_HIGH: u128 = 89812638168441061617712796123820912833;

    // Percentage value of Yin's total supply that can be flash minted (wad)
    const FLASH_MINT_AMOUNT_PCT: u128 = 50000000000000000;

    struct Storage {
        shrine_addr: ContractAddress, 
    }

    #[external]
    fn FlashMint(
        initiator: ContractAddress, receiver: ContractAddress, token: ContractAddress, amount: u256
    ) {}

    #[constructor]
    fn constructor(shrine: ContractAddress) {
        shrine_addr::write(shrine);
    }

    #[view]
    fn maxFlashLoan(token: ContractAddress) -> u256 {
        let shrine: ContractAddress = shrine_addr::read();

        // Can only flash mint our own synthetic
        if token == shrine {
            let supply = Wad {
                val: IERC20Dispatcher {
                    contract_address: shrine
                }.total_supply().try_into().unwrap()
            };
            return u256 { low: (supply * Wad { val: FLASH_MINT_AMOUNT_PCT }).val, high: 0 };
        }
        u256 { low: 0, high: 0 }
    }

    #[view]
    fn flashFee(token: ContractAddress, amount: u256) -> u256 {
        // as per EIP3156, if a token is not supported, this function must revert
        // and we only support flash minting of own synthetic
        assert(shrine_addr::read() == token, 'Unsupported token');

        // Feeless minting
        u256 { low: 0, high: 0 }
    }

    #[external]
    fn flashLoan(
        receiver: ContractAddress,
        token: ContractAddress,
        amount: u256,
        calldata_arr: Array<felt252>
    ) -> bool {
        // prevents looping which would lead to excessive minting
        // we only allow a FLASH_MINT_AMOUNT_PCT percentage of total
        // yin to be minted, as per spec
        // TODO: Implement reentrancy guard when contract composition solution is released
        //ReentrancyGuard._start();

        let fee: u256 = flashFee(token, amount);

        assert(amount <= maxFlashLoan(token), 'amount exceeds maximum');

        let shrine = IShrineDispatcher { contract_address: shrine_addr::read() };

        let amount_wad = Wad { val: amount.try_into().unwrap() };

        shrine.inject(receiver, amount_wad);

        let initiator: ContractAddress = starknet::get_caller_address();

        let borrower_resp: u256 = IFlashBorrowerDispatcher {
            contract_address: receiver
        }.onFlashLoan(initiator, token, amount, fee, calldata_arr);

        assert(
            borrower_resp.low == ON_FLASH_MINT_SUCCESS_LOW & borrower_resp.high == ON_FLASH_MINT_SUCCESS_HIGH,
            'onFlashLoan callback failed'
        );

        // This function in Shrine takes care of balance validation
        shrine.eject(receiver, amount_wad);

        FlashMint(initiator, receiver, token, amount);

        //ReentrancyGuard._end();
        true
    }
}
