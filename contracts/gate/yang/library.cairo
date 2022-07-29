%lang starknet

from starkware.cairo.common.bool import TRUE, FALSE
from starkware.cairo.common.cairo_builtins import HashBuiltin
from starkware.cairo.common.uint256 import Uint256
from starkware.starknet.common.syscalls import get_contract_address

from contracts.interfaces import IShrine
# these imported public functions are part of the contract's interface
from contracts.lib.openzeppelin.security.reentrancyguard import ReentrancyGuard
from contracts.shared.interfaces import IERC20
from contracts.shared.types import Yang
from contracts.shared.wad_ray import WadRay

#
# Events
#

@event
func Killed():
end

@event
func Deposit(user, trove_id, assets_wad, shares_wad):
end

@event
func Redeem(user, trove_id, assets_wad, shares_wad):
end

#
# Storage
#

@storage_var
func gate_shrine_storage() -> (address):
end

@storage_var
func gate_asset_storage() -> (address):
end

@storage_var
func gate_live_storage() -> (bool):
end

# Last updated total balance of underlying asset
# Used to detect changes in total balance due to rebasing
@storage_var
func gate_last_asset_balance_storage() -> (wad):
end

#
# Getters
#

namespace Gate:
    #
    # Constructor
    #

    func initializer{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
        shrine_address, asset_address
    ):
        gate_shrine_storage.write(shrine_address)
        gate_asset_storage.write(asset_address)
        gate_live_storage.write(TRUE)
        return ()
    end

    # Getters

    func get_shrine{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (
        address
    ):
        return gate_shrine_storage.read()
    end

    func get_asset{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (
        address
    ):
        return gate_asset_storage.read()
    end

    func get_live{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (bool):
        return gate_live_storage.read()
    end

    func get_last_asset_balance{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
        ) -> (wad):
        return gate_last_asset_balance_storage.read()
    end

    func get_total_assets{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (
        wad
    ):
        let (asset_address) = get_asset()
        let (gate_address) = get_contract_address()
        let (total_uint : Uint256) = IERC20.balanceOf(
            contract_address=asset_address, account=gate_address
        )
        let (total_wad) = WadRay.from_uint(total_uint)
        return (total_wad)
    end

    func get_total_yang{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (
        wad
    ):
        let (shrine_address) = get_shrine()
        let (asset_address) = get_asset()
        let (yang_info : Yang) = IShrine.get_yang(
            contract_address=shrine_address, yang_address=asset_address
        )
        return (yang_info.total)
    end

    func get_exchange_rate{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (
        wad
    ):
        let (total_supply_wad) = get_total_yang()
        let (total_balance) = get_last_asset_balance()

        # Catch division by zero errors
        if total_supply_wad == 0:
            return (0)
        end

        let (exchange_rate) = WadRay.wunsigned_div_unchecked(total_balance, total_supply_wad)
        return (exchange_rate)
    end

    #
    # External
    #

    func kill{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}():
        gate_live_storage.write(FALSE)
        Killed.emit()
        return ()
    end

    func deposit{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
        user_address, trove_id, assets
    ) -> (wad):
        alloc_locals

        # Assert live
        assert_live()

        # Get asset and gate addresses
        let (asset_address) = get_asset()
        let (gate_address) = get_contract_address()

        let (shares) = deposit_internal(asset_address, gate_address, user_address, trove_id, assets)

        # Update before deposit
        update_last_asset_balance(asset_address, gate_address)

        return (shares)
    end

    func redeem{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
        user_address, trove_id, shares
    ) -> (wad):
        alloc_locals

        # Get asset and gate addresses
        let (asset_address) = get_asset()
        let (gate_address) = get_contract_address()

        let (assets) = redeem_internal(asset_address, gate_address, user_address, trove_id, shares)

        # Update before redeem
        update_last_asset_balance(asset_address, gate_address)

        return (assets)
    end

    # Updates the asset balance of the Gate.
    func sync{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}():
        alloc_locals

        # Get asset and gate addresses
        let (asset_address) = get_asset()
        let (gate_address) = get_contract_address()
        update_last_asset_balance(asset_address, gate_address)
        return ()
    end

    #
    # Internal
    #

    func assert_live{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}():
        # Check system is live
        let (live) = gate_live_storage.read()
        with_attr error_message("Gate: Gate is not live"):
            assert live = TRUE
        end
        return ()
    end

    func convert_to_assets{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
        shares
    ) -> (wad):
        alloc_locals

        let (total_supply_wad) = get_total_yang()

        if total_supply_wad == 0:
            return (shares)
        else:
            let (total_assets_wad) = get_total_assets()
            let (product) = WadRay.wmul(shares, total_assets_wad)
            let (assets_wad) = WadRay.wunsigned_div_unchecked(product, total_supply_wad)
            return (assets_wad)
        end
    end

    func convert_to_shares{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
        assets_wad
    ) -> (wad):
        alloc_locals

        let (total_supply_wad) = get_total_yang()

        if total_supply_wad == 0:
            return (assets_wad)
        else:
            let (product) = WadRay.wmul(assets_wad, total_supply_wad)
            let (total_assets_wad) = get_total_assets()
            let (shares) = WadRay.wunsigned_div_unchecked(product, total_assets_wad)
            return (shares)
        end
    end

    func deposit_internal{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
        asset_address, gate_address, user_address, trove_id, assets_wad
    ) -> (wad):
        alloc_locals

        let (shares_wad) = convert_to_shares(assets_wad)
        if shares_wad == 0:
            return (0)
        end

        # Update Shrine
        let (shrine_address) = get_shrine()
        IShrine.deposit(
            contract_address=shrine_address,
            yang_address=asset_address,
            amount=shares_wad,
            trove_id=trove_id,
        )

        # Transfer asset from `user_address` to Gate
        let (assets_uint) = WadRay.to_uint(assets_wad)
        with_attr error_message("Gate: Transfer of asset failed"):
            ReentrancyGuard._start()
            let (success) = IERC20.transferFrom(
                contract_address=asset_address,
                sender=user_address,
                recipient=gate_address,
                amount=assets_uint,
            )
            ReentrancyGuard._end()
            assert success = TRUE
        end

        Deposit.emit(
            user=user_address, trove_id=trove_id, assets_wad=assets_wad, shares_wad=shares_wad
        )

        return (shares_wad)
    end

    func redeem_internal{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
        asset_address, gate_address, user_address, trove_id, shares
    ) -> (wad):
        alloc_locals

        let (assets_wad) = convert_to_assets(shares)
        if assets_wad == 0:
            return (0)
        end

        let (shrine_address) = get_shrine()

        IShrine.withdraw(
            contract_address=shrine_address,
            yang_address=asset_address,
            amount=shares,
            trove_id=trove_id,
        )

        let (assets_uint : Uint256) = WadRay.to_uint(assets_wad)

        with_attr error_message("Gate: Transfer of asset failed"):
            ReentrancyGuard._start()
            let (success) = IERC20.transfer(
                contract_address=asset_address, recipient=user_address, amount=assets_uint
            )
            ReentrancyGuard._end()
            assert success = TRUE
        end

        Redeem.emit(user=user_address, trove_id=trove_id, assets_wad=assets_wad, shares_wad=shares)

        return (assets_wad)
    end

    # Helper function to update the underlying balance after a user action
    func update_last_asset_balance{
        syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr
    }(asset_address, gate_address):
        let (balance_uint : Uint256) = IERC20.balanceOf(
            contract_address=asset_address, account=gate_address
        )
        let (balance_wad) = WadRay.from_uint(balance_uint)
        gate_last_asset_balance_storage.write(balance_wad)
        return ()
    end
end
