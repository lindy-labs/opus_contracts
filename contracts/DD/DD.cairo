// TODO:
// * write documentation
//   functions, inline comments
// * from the WP "stablecoins deposited this way are lent out to trusted money market protocols in order to generate yield, driving the global collateralization ratio up"
//   as @CrisBRM said in Slack, these should be deposited to Aave and Sandclock, once they are available on StarkNet (Sandclock has priority, but Aave will prob launch sooner)
// * we should have deploy scripts; there are interdependencies between various modules, take that into account
// * is there a good way to assure that amount that's passed to deposit/withdraw is already scaled? do we need to check for it even?
// * use Safemath
// * should Deposit and Withdrawal events have addresses?

//
// Direct Deposit of an approved stablecoin
// allows to mint USDa via depositing a stablecoin (DAI, USDC),
// there's one instance of this contract deployed per stablecoin
//

%lang starknet

from starkware.cairo.common.bool import TRUE
from starkware.cairo.common.cairo_builtins import HashBuiltin
from starkware.cairo.common.math import (
    assert_not_zero,
    assert_le,
    assert_in_range,
    unsigned_div_rem,
)
from starkware.cairo.common.pow import pow
from starkware.cairo.common.uint256 import (
    Uint256,
    uint256_eq,
    uint256_le,
    uint256_mul,
    uint256_sub,
    uint256_unsigned_div_rem,
)
from starkware.starknet.common.syscalls import get_caller_address, get_contract_address

from contracts.lib.convert import felt_to_uint, uint_to_felt_unchecked
from contracts.lib.interfaces import IERC20, IERC20Mintable, IERC20Burnable, IUSDa
from contracts.lib.openzeppelin.access.ownable.ownable import Ownable

const HUNDRED_PERCENT_BPS = 10000;  // 100%
// bounds used to check the allowed value of the
// threshold when direct deposit minting is permitted
const THRESHOLD_BUFFER_LOWER_BOUND = 500;  // 5%
const THRESHOLD_BUFFER_UPPER_BOUND = 10000;  // 100%

//
// Events
//

@event
func ThresholdBufferChange(old_value: felt, new_value: felt) {
}

@event
func ReserveAddressChange(old_value: felt, new_value: felt) {
}

@event
func StabilityFeeChange(old_value: felt, new_value: felt) {
}

@event
func TreasuryAddressChange(old_value: felt, new_value: felt) {
}

@event
func Deposit(amount: Uint256) {
}

@event
func Withdrawal(amount: Uint256) {
}

//
// Storage
//

// value in basis points that the target collateralization ratio is
// multiplied by to get minimal ratio when direct minting is enabled
// the value has to be in allowed range
@storage_var
func DD_threshold_buffer_storage() -> (value: felt) {
}

// address of Aura reserve
@storage_var
func DD_reserve_address_storage() -> (addr: felt) {
}

// stability fee in basis points
@storage_var
func DD_stability_fee_storage() -> (fee: felt) {
}

// address of underlying stablecoin that can be directly deposited to get USDa
@storage_var
func DD_stablecoin_address_storage() -> (addr: felt) {
}

// multiplier between stablecoin and USDa amounts
@storage_var
func DD_scale_factor_storage() -> (decimals: Uint256) {
}

// address of Aura treasury
@storage_var
func DD_treasury_address_storage() -> (addr: felt) {
}

// address of the USDa token contract
@storage_var
func DD_usda_address_storage() -> (addr: felt) {
}

//
// Getters
//

@view
func get_threshold_buffer{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (
    value: felt
) {
    let (value) = DD_threshold_buffer_storage.read();
    return (value,);
}

@view
func get_owner_address{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (
    addr: felt
) {
    let (addr) = Ownable.owner();
    return (addr,);
}

@view
func get_reserve_address{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (
    addr: felt
) {
    let (addr) = DD_reserve_address_storage.read();
    return (addr,);
}

@view
func get_stability_fee{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (
    fee: felt
) {
    let (fee) = DD_stability_fee_storage.read();
    return (fee,);
}

@view
func get_stablecoin_address{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (
    addr: felt
) {
    let (addr) = DD_stablecoin_address_storage.read();
    return (addr,);
}

@view
func get_treasury_address{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (
    addr: felt
) {
    let (addr) = DD_treasury_address_storage.read();
    return (addr,);
}

@view
func get_usda_address{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (
    addr: felt
) {
    let (addr) = DD_usda_address_storage.read();
    return (addr,);
}

//
// Setters
//

@external
func set_threshold_buffer{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    value: felt
) {
    Ownable.assert_only_owner();
    with_attr error_message("DD: value {value} out of bounds") {
        // value is in basis points, has to be between lower and
        // upper bound (inclusive, that's why the +1)
        assert_in_range(value, THRESHOLD_BUFFER_LOWER_BOUND, THRESHOLD_BUFFER_UPPER_BOUND + 1);
    }

    let (old) = DD_threshold_buffer_storage.read();
    DD_threshold_buffer_storage.write(value);

    ThresholdBufferChange.emit(old, value);

    return ();
}

@external
func set_owner{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(addr: felt) {
    // this function already does only owner and zero address checks internally
    // and also emits an event
    Ownable.transfer_ownership(addr);
    return ();
}

@external
func set_reserve_address{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    addr: felt
) {
    Ownable.assert_only_owner();
    with_attr error_message("DD: address cannot be zero") {
        assert_not_zero(addr);
    }

    let (old) = DD_reserve_address_storage.read();
    DD_reserve_address_storage.write(addr);

    ReserveAddressChange.emit(old, addr);

    return ();
}

@external
func set_stability_fee{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(fee: felt) {
    Ownable.assert_only_owner();
    with_attr error_message("DD: invalid stability fee") {
        assert_le(fee, HUNDRED_PERCENT_BPS);
    }

    let (old) = DD_stability_fee_storage.read();
    DD_stability_fee_storage.write(fee);

    StabilityFeeChange.emit(old, fee);

    return ();
}

@external
func set_treasury_address{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    addr: felt
) {
    Ownable.assert_only_owner();
    with_attr error_message("DD: address cannot be zero") {
        assert_not_zero(addr);
    }

    let (old) = DD_treasury_address_storage.read();
    DD_treasury_address_storage.write(addr);

    TreasuryAddressChange.emit(old, addr);

    return ();
}

//
// Constructor
//

@constructor
func constructor{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    owner: felt,
    stablecoin_addr: felt,
    usda_addr: felt,
    reserve_addr: felt,
    treasury_addr: felt,
    stability_fee: felt,
    threshold_buffer: felt,
) {
    Ownable.initializer(owner);
    DDS_initializer(
        stablecoin_addr, usda_addr, reserve_addr, treasury_addr, stability_fee, threshold_buffer
    );
    return ();
}

//
// View functions
//

@view
func get_max_mint_amount{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (
    amount: Uint256
) {
    // let (usda_address : felt) = DD_usda_address_storage.read()

    // # TODO: getting the total collateral of USDa is done here via a call
    // #       to the USDa contract, but it's just a placeholder and could (maybe even should)
    // #       be changed; I just used it as a temporary solution during dev, don't
    // #       be afraid to make it better -- milan
    // let (total_collateral : felt) = IUSDa.get_total_collateral(contract_address=usda_address)

    // # TODO: what unit is this in? based on that, do the +25% calculation below
    // # correctly; currently assuming basis points
    // let (target_collateralization_ratio : felt) = IUSDa.get_target_collateralization_ratio(
    //     contract_address=usda_address
    // )

    // let (threshold_buffer : felt) = DD_threshold_buffer_storage.read()
    // let (usda_balance_uint : Uint256) = IERC20.totalSupply(contract_address=usda_addr)
    // let (usda_balance : felt) = uint_to_felt_unchecked(usda_balance_uint)

    // let (amount : felt) = calculate_max_mint_amount(
    //     total_collateral, target_collateralization_ratio, threshold_buffer, usda_balance
    // )
    // let (amount_uint : Uint256) = uint_to_felt_unchecked(amount)
    // return (amount_uint)

    // temporary during dev only, once the above TODOs
    // are resolved, do it properly
    let ten_thousand = 10000000000000000000000;  // 10_000 * 10**18
    return (Uint256(low=ten_thousand, high=0),);
}

//
// Externals
//

// stablecoin -> USDa
// amount of stablecoin that's being deposited, should be scaled by stablecoin decimals
// e.g. 1 DAI == 10**18, 1 USDC == 10**6
@external
func deposit{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    stablecoin_amount: Uint256
) {
    alloc_locals;

    // TODO: check if can mint:
    //   max_mint_amount
    //   collat ratio
    //   should there be a check to see what would be the result of this mint
    //   and if it the delta is too big, revert?

    let (max_mint: Uint256) = get_max_mint_amount();
    with_attr error_message("DD: deposit amount exceeds mint limit") {
        let (is_in_limit) = uint256_le(stablecoin_amount, max_mint);
        assert is_in_limit = TRUE;
    }

    let (caller_address: felt) = get_caller_address();
    let (recipient_address: felt) = get_contract_address();
    let (stablecoin_address: felt) = DD_stablecoin_address_storage.read();

    let (transfer_did_succeed: felt) = IERC20.transferFrom(
        contract_address=stablecoin_address,
        sender=caller_address,
        recipient=recipient_address,
        amount=stablecoin_amount,
    );
    with_attr error_message("DD: transferFrom failed") {
        assert transfer_did_succeed = TRUE;
    }

    let (scale_factor: Uint256) = DD_scale_factor_storage.read();
    let (mint_amount: Uint256, _) = uint256_mul(stablecoin_amount, scale_factor);
    let (stability_fee: felt) = DD_stability_fee_storage.read();
    let (
        caller_amount: Uint256, reserve_amount: Uint256, treasury_amount: Uint256
    ) = calculate_mint_distribution(stability_fee, mint_amount);

    let (usda_address: felt) = DD_usda_address_storage.read();
    let (reserve_address: felt) = DD_reserve_address_storage.read();
    let (treasury_address: felt) = DD_treasury_address_storage.read();

    IERC20Mintable.mint(
        contract_address=usda_address, recipient=caller_address, amount=caller_amount
    );
    IERC20Mintable.mint(
        contract_address=usda_address, recipient=reserve_address, amount=reserve_amount
    );
    IERC20Mintable.mint(
        contract_address=usda_address, recipient=treasury_address, amount=treasury_amount
    );

    Deposit.emit(stablecoin_amount);

    return ();
}

// USDa -> stablecoin
// amount of stablecoin that's being withdrawn, should be scaled by stablecoin decimals
// e.g. 1 DAI == 10**18, 1 USDC == 10**6
@external
func withdraw{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    stablecoin_amount: Uint256
) {
    let (scale_factor: Uint256) = DD_scale_factor_storage.read();
    let (burn_amount: Uint256, _) = uint256_mul(stablecoin_amount, scale_factor);
    let (caller_address: felt) = get_caller_address();
    let (usda_address: felt) = DD_usda_address_storage.read();
    let (stablecoin_address: felt) = DD_stablecoin_address_storage.read();

    IERC20Burnable.burn(contract_address=usda_address, owner=caller_address, amount=burn_amount);
    IERC20.transfer(
        contract_address=stablecoin_address, recipient=caller_address, amount=stablecoin_amount
    );

    Withdrawal.emit(stablecoin_amount);

    return ();
}

//
// internal
//

func DDS_initializer{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    stablecoin_address: felt,
    usda_address: felt,
    reserve_address: felt,
    treasury_address: felt,
    stability_fee: felt,
    threshold_buffer: felt,
) {
    alloc_locals;

    with_attr error_message("DD: address cannot be zero") {
        assert_not_zero(stablecoin_address);
        assert_not_zero(usda_address);
        assert_not_zero(reserve_address);
        assert_not_zero(treasury_address);
    }

    with_attr error_message("DD: invalid stability fee") {
        assert_le(stability_fee, HUNDRED_PERCENT_BPS);
    }

    with_attr error_message("DD: threshold buffer is out of bounds") {
        // value is in basis points, has to be between 10% and 50% (inclusive)
        assert_in_range(threshold_buffer, 1000, 5001);
    }

    let (stablecoin_decimals: felt) = IERC20.decimals(contract_address=stablecoin_address);
    let (usda_decimals: felt) = IERC20.decimals(contract_address=usda_address);
    with_attr error_message("DD: incompatible stablecoin") {
        assert_le(stablecoin_decimals, usda_decimals);
    }

    let (power) = pow(10, usda_decimals - stablecoin_decimals);
    // these three variables are only ever set once, here,
    // during the deployment of the contract
    DD_scale_factor_storage.write(Uint256(low=power, high=0));
    DD_stablecoin_address_storage.write(stablecoin_address);
    DD_usda_address_storage.write(usda_address);

    // the rest is configurable via setters
    DD_reserve_address_storage.write(reserve_address);
    DD_treasury_address_storage.write(treasury_address);
    DD_stability_fee_storage.write(stability_fee);
    DD_threshold_buffer_storage.write(threshold_buffer);

    return ();
}

func calculate_max_mint_amount{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    total_collateral: felt,
    target_collateralization_ratio: felt,
    threshold_buffer: felt,
    usda_balance: felt,
) -> (amount: felt) {
    // formula (11) in the whitepaper:
    // maxDirectMintAmount(t) = (collateralPool(t) / minDirectMintRatio) - totalUSDa(t)
    // where minDirectMintRatio is a function of the target c-ratio and a buffer

    let min_direct_mint_ratio: felt = target_collateralization_ratio + threshold_buffer;
    let max_mint_amount: felt = (total_collateral * min_direct_mint_ratio) - usda_balance;

    return (max_mint_amount,);
}

func calculate_mint_distribution{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    stability_fee: felt, mint_amount: Uint256
) -> (to_depositor: Uint256, to_reserve: Uint256, to_treasury: Uint256) {
    alloc_locals;

    let (depositor_gets_bps: Uint256) = felt_to_uint(HUNDRED_PERCENT_BPS - stability_fee);
    let (depositor_amount_mul: Uint256, carry: Uint256) = uint256_mul(
        mint_amount, depositor_gets_bps
    );
    with_attr error_message("DD: mint amount too high") {
        let (no_carry) = uint256_eq(Uint256(0, 0), carry);
        assert no_carry = TRUE;
    }

    // we don't care about the reminder as that gets distributed
    // to the reserve and treasury
    let (depositor_amount: Uint256, _) = uint256_unsigned_div_rem(
        depositor_amount_mul, Uint256(low=HUNDRED_PERCENT_BPS, high=0)
    );

    // split the stability amount between reserve and treasury,
    // with the treasury getting the reminder in case of an uneven split
    let stability_amount: Uint256 = uint256_sub(mint_amount, depositor_amount);
    let (reserve_amount: Uint256, _) = uint256_unsigned_div_rem(
        stability_amount, Uint256(low=2, high=0)
    );
    let treasury_amount: Uint256 = uint256_sub(stability_amount, reserve_amount);

    return (depositor_amount, reserve_amount, treasury_amount);
}
