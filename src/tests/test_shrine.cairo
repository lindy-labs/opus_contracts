#[cfg(test)]
mod TestShrine {
    use array::{ArrayTrait, SpanTrait};
    use option::OptionTrait;
    use traits::{Into, TryInto};
    use starknet::{contract_address_const, deploy_syscall, ClassHash, class_hash_try_from_felt252, ContractAddress, contract_address_to_felt252, SyscallResultTrait};
    use starknet::contract_address::ContractAddressZeroable;
    use starknet::testing::{set_caller_address, set_block_timestamp};

    use aura::core::shrine::Shrine;

    use aura::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use aura::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use aura::utils::wadray;
    use aura::utils::wadray::{Wad, WAD_DECIMALS, Ray, RAY_ONE};

    // Arbitrary timestamp set to approximately 18 May 2023, 7:55:28am UTC
    const DEPLOYMENT_TIMESTAMP: u64 = 1684390000_u64;

    // Shrine ERC-20 constants
    const YIN_NAME: felt252 = 'Cash';
    const YIN_SYMBOL: felt252 = 'CASH';

    fn admin() -> ContractAddress {
        contract_address_const::<0x1337>()
    }

    fn setup() -> ContractAddress {
        set_block_timestamp(DEPLOYMENT_TIMESTAMP);

        let admin = contract_address_to_felt252(admin());

        let mut calldata = ArrayTrait::new();
        calldata.append(admin);
        calldata.append(YIN_NAME);
        calldata.append(YIN_SYMBOL);

        let shrine_class_hash: ClassHash = class_hash_try_from_felt252(Shrine::TEST_CLASS_HASH).unwrap();
        let (shrine_address, _) = deploy_syscall(
            shrine_class_hash, 0, calldata.span(), false
        ).unwrap_syscall();

        shrine_address
    }

    #[test]
    #[available_gas(2000000000)]
    fn test_shrine_setup() {
        let shrine_addr: ContractAddress = setup();

        // Check ERC-20 getters
        let yin: IERC20Dispatcher = IERC20Dispatcher { contract_address: shrine_addr };
        assert(yin.name() == YIN_NAME, 'wrong name');
        assert(yin.symbol() == YIN_SYMBOL, 'wrong symbol');
        assert(yin.decimals() == WAD_DECIMALS, 'wrong decimals');

        // Check Shrine getters
        let shrine: IShrineDispatcher = IShrineDispatcher { contract_address: shrine_addr };
        assert(shrine.get_live(), 'not live');
        let (multiplier, _, _) = shrine.get_current_multiplier();
        assert(multiplier == RAY_ONE.into(), 'wrong multiplier');
    }
}
