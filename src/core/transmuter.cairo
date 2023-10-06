#[starknet::contract]
mod Transmuter {
    use cmp::min;
    use integer::{BoundedU128, BoundedU256};
    use starknet::{ContractAddress, get_caller_address, get_contract_address};
    use starknet::contract_address::ContractAddressZeroable;

    use opus::core::roles::TransmuterRoles;

    use opus::interfaces::IERC20::{IERC20, IERC20Dispatcher, IERC20DispatcherTrait};
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::interfaces::ITransmuter::ITransmuter;
    use opus::types::AssetBalance;
    use opus::utils::access_control::{AccessControl, IAccessControl};
    use opus::utils::wadray;
    use opus::utils::wadray::{Ray, RayZeroable, RAY_ONE, Wad, WadZeroable, WAD_DECIMALS, WAD_ONE};

    //
    // Constants
    //

    // Upper bound of the maximum amount of yin that can be minted via this Transmuter as a 
    // percentage of total yin supply: 10% (Ray)
    const PERCENTAGE_CAP_UPPER_BOUND: u128 = 100000000000000000000000000;

    // Upper bound of the fee as a percentage that can be charged when swapping
    // yin for the asset when `reverse` is enabled: 1% (Ray)
    // This is not set at deployment so it defaults to 0%.
    const REVERSE_FEE_UPPER_BOUND: u128 = 10000000000000000000000000;

    #[storage]
    struct Storage {
        // The Shrine associated with this Transmuter
        shrine: IShrineDispatcher,
        // The asset that can be swapped for yin via this Transmuter
        asset: IERC20Dispatcher,
        // The total yin transmuted 
        total_transmuted: Wad,
        // The maximum amount of assets that can be swapped for yin via this Transmuter
        ceiling: u128,
        // The maximum amount of yin that can be minted via this Transmuter
        // as a percentage of the total yin supply
        percentage_cap: Ray,
        // Keeps track of whether the Transmuter currently allows for users
        // to burn yin and receive the asset
        reversibility: bool,
        // Fee to be charged for each `reverse` transaction
        reverse_fee: Ray,
        // Keeps track of whether the Transmuter is live or killed
        is_live: bool,
        // The address to receive any excess assets
        receiver: ContractAddress,
    }

    //
    // Events
    //

    #[event]
    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    enum Event {
        Killed: Killed,
        CeilingUpdated: CeilingUpdated,
        PercentageCapUpdated: PercentageCapUpdated,
        Transmute: Transmute,
        Reverse: Reverse,
        ReversibilityToggled: ReversibilityToggled,
        ReverseFeeUpdated: ReverseFeeUpdated,
        Sweep: Sweep,
        ReceiverUpdated: ReceiverUpdated,
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct Killed {}

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct CeilingUpdated {
        old_ceiling: u128,
        new_ceiling: u128
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct PercentageCapUpdated {
        cap: Ray
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct Transmute {
        #[key]
        user: ContractAddress,
        asset_amt: u128,
        yin_amt: Wad
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct Reverse {
        #[key]
        user: ContractAddress,
        asset_amt: u128,
        yin_amt: Wad,
        fee: u128
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct ReversibilityToggled {
        reversibility: bool
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct ReverseFeeUpdated {
        old_fee: Ray,
        new_fee: Ray
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct Sweep {
        #[key]
        recipient: ContractAddress,
        asset_amt: u128
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct ReceiverUpdated {
        old_receiver: ContractAddress,
        new_receiver: ContractAddress
    }

    // Constructor

    #[constructor]
    fn constructor(
        ref self: ContractState,
        admin: ContractAddress,
        shrine: ContractAddress,
        asset: ContractAddress,
        receiver: ContractAddress,
        percentage_cap: Ray,
    ) {
        AccessControl::initializer(admin, Option::Some(TransmuterRoles::default_admin_role()));

        self.shrine.write(IShrineDispatcher { contract_address: shrine });
        self.asset.write(IERC20Dispatcher { contract_address: asset });

        self.set_receiver_helper(receiver);
        self.set_percentage_cap_helper(percentage_cap);
    }

    #[external(v0)]
    impl ITransmuterImpl of ITransmuter<ContractState> {
        //
        // Getters
        //
        fn get_asset(self: @ContractState) -> ContractAddress {
            self.asset.read().contract_address
        }

        fn get_ceiling(self: @ContractState) -> u128 {
            self.ceiling.read()
        }

        fn get_percentage_cap(self: @ContractState) -> Ray {
            self.percentage_cap.read()
        }

        fn get_receiver(self: @ContractState) -> ContractAddress {
            self.receiver.read()
        }

        fn get_reversibility(self: @ContractState) -> bool {
            self.reversibility.read()
        }

        fn get_reverse_fee(self: @ContractState) -> Ray {
            self.reverse_fee.read()
        }

        fn get_live(self: @ContractState) -> bool {
            self.is_live.read()
        }

        //
        // Setters
        //

        fn set_ceiling(ref self: ContractState, ceiling: u128) {
            AccessControl::assert_has_role(TransmuterRoles::SET_CEILING);
            let old_ceiling: u128 = self.ceiling.read();
            self.ceiling.write(ceiling);

            self.emit(CeilingUpdated { old_ceiling, new_ceiling: ceiling });
        }

        fn set_percentage_cap(ref self: ContractState, cap: Ray) {
            AccessControl::assert_has_role(TransmuterRoles::SET_PERCENTAGE_CAP);

            self.set_percentage_cap_helper(cap);
        }

        fn set_receiver(ref self: ContractState, receiver: ContractAddress) {
            AccessControl::assert_has_role(TransmuterRoles::SET_RECEIVER);

            self.set_receiver_helper(receiver);
        }

        fn toggle_reversibility(ref self: ContractState) {
            AccessControl::assert_has_role(TransmuterRoles::TOGGLE_REVERSIBILITY);

            let reversibility: bool = !self.reversibility.read();
            self.reversibility.write(reversibility);
            self.emit(ReversibilityToggled { reversibility });
        }

        fn set_reverse_fee(ref self: ContractState, fee: Ray) {
            AccessControl::assert_has_role(TransmuterRoles::SET_REVERSE_FEE);

            assert(fee <= REVERSE_FEE_UPPER_BOUND.into(), 'TR: Exceeds max fee');
            let old_fee: Ray = self.reverse_fee.read();
            self.reverse_fee.write(fee);

            self.emit(ReverseFeeUpdated { old_fee, new_fee: fee });
        }

        // 
        // Core functions
        //

        // Swaps the stablecoin asset for yin at a ratio of 1 : 1, scaled to Wad precision.
        // Dummy tokens are minted 1 : 1 for asset, scaled to Wad precision.
        // Reverts if:
        // 1. User has insufficent assets; or
        // 2. Ceiling will be exceeded
        fn transmute(ref self: ContractState, asset_amt: u128) {
            let asset: IERC20Dispatcher = self.asset.read();
            let yin_amt: Wad = wadray::fixed_point_to_wad(asset_amt, asset.decimals());
            self.assert_can_transmute(yin_amt);

            let user: ContractAddress = get_caller_address();

            self.total_transmuted.write(self.total_transmuted.read() + yin_amt);
            self.shrine.read().inject(user, yin_amt);

            // Transfer asset to Transmuter
            let transmuter: ContractAddress = get_contract_address();
            let success: bool = asset.transfer_from(user, transmuter, asset_amt.into());
            assert(success, 'TR: Asset transfer failed');

            self.emit(Transmute { user, asset_amt, yin_amt });
        }

        // Swaps yin for the stablecoin asset at a ratio of 1 : 1, scaled down from Wad precision.
        // Reverts if:
        // 1. User has insufficient yin; or
        // 2. Transmuter has insufficent assets corresponding to the burnt yin
        fn reverse(ref self: ContractState, yin_amt: Wad) {
            self.assert_reversibility();

            // Burn yin from user
            let user: ContractAddress = get_caller_address();
            self.shrine.read().eject(user, yin_amt);

            // Transfer asset to user
            let asset: IERC20Dispatcher = self.asset.read();
            let asset_amt: u128 = wadray::wad_to_fixed_point(yin_amt, asset.decimals());
            let fee: u128 = self.get_reverse_fee_helper(asset_amt);

            self.total_transmuted.write(self.total_transmuted.read() - yin_amt);
            self.shrine.read().eject(user, yin_amt);

            let user_asset_amt: u128 = asset_amt - fee;
            let success: bool = asset.transfer(user, user_asset_amt.into());
            assert(success, 'TR: Asset transfer failed');

            self.emit(Reverse { user, asset_amt: user_asset_amt, yin_amt, fee });
        }

        // Transfers all assets in the transmuter to the receiver
        fn sweep(ref self: ContractState) {
            AccessControl::assert_has_role(TransmuterRoles::SWEEP);

            let asset: IERC20Dispatcher = self.asset.read();
            let asset_balance: u256 = asset.balance_of(get_contract_address());
            let recipient: ContractAddress = self.receiver.read();
            asset.transfer(recipient, asset_balance);

            self.emit(Sweep { recipient, asset_amt: asset_balance.try_into().unwrap() });
        }

        //
        // Shutdown
        //

        fn kill(ref self: ContractState) {
            AccessControl::assert_has_role(TransmuterRoles::KILL);
            self.is_live.write(false);
            self.emit(Killed {});
        }

        // Note that the amount of asset that can be claimed is no longer pegged 1 : 1
        // because we do not make any assumptions as to the amount of assets held by the 
        // Transmuter.
        fn claim(ref self: ContractState, yin_amt: Wad) {
            assert(self.is_live.read(), 'TR: Transmuter is live');

            let transmuter: ContractAddress = get_contract_address();
            let user: ContractAddress = get_caller_address();

            let asset: IERC20Dispatcher = self.asset.read();
            let asset_balance: u256 = asset.balance_of(transmuter);

            let asset_amt: Wad = (yin_amt / self.total_transmuted.read())
                * asset_balance.try_into().unwrap();

            self.shrine.read().eject(user, yin_amt);
            asset.transfer(user, asset_amt.into());
        }
    }

    #[generate_trait]
    impl TransmuterHelpers of TransmuterHelpersTrait {
        #[inline(always)]
        fn assert_can_transmute(self: @ContractState, amt_to_mint: Wad) {
            let shrine: IShrineDispatcher = self.shrine.read();
            let yin_price_ge_peg: bool = shrine.get_yin_spot_price() >= WAD_ONE.into();

            let cap: Wad = wadray::rmul_wr(shrine.get_total_yin(), self.percentage_cap.read());
            let minted: Wad = self.total_transmuted.read();
            let is_lt_cap: bool = minted + amt_to_mint <= cap;

            assert(yin_price_ge_peg && is_lt_cap, 'TR: Transmute is paused');
        }

        #[inline(always)]
        fn assert_reversibility(self: @ContractState) {
            assert(self.reversibility.read(), 'TR: Reverse is paused');
        }

        fn set_receiver_helper(ref self: ContractState, receiver: ContractAddress) {
            assert(receiver.is_non_zero(), 'TR: Zero address');
            let old_receiver: ContractAddress = self.receiver.read();
            self.receiver.write(receiver);

            self.emit(ReceiverUpdated { old_receiver, new_receiver: receiver });
        }

        fn set_percentage_cap_helper(ref self: ContractState, cap: Ray) {
            assert(cap <= PERCENTAGE_CAP_UPPER_BOUND.into(), 'TR: Exceeds upper bound of 10%');
            self.percentage_cap.write(cap);

            self.emit(PercentageCapUpdated { cap });
        }

        fn get_reverse_fee_helper(self: @ContractState, asset_amt: u128) -> u128 {
            let fee: Ray = self.reverse_fee.read();
            if fee.is_zero() {
                return 0;
            }

            wadray::rmul_wr(asset_amt.into(), fee).val
        }
    }

    //
    // Public AccessControl functions
    //

    #[external(v0)]
    impl IAccessControlImpl of IAccessControl<ContractState> {
        fn get_roles(self: @ContractState, account: ContractAddress) -> u128 {
            AccessControl::get_roles(account)
        }

        fn has_role(self: @ContractState, role: u128, account: ContractAddress) -> bool {
            AccessControl::has_role(role, account)
        }

        fn get_admin(self: @ContractState) -> ContractAddress {
            AccessControl::get_admin()
        }

        fn get_pending_admin(self: @ContractState) -> ContractAddress {
            AccessControl::get_pending_admin()
        }

        fn grant_role(ref self: ContractState, role: u128, account: ContractAddress) {
            AccessControl::grant_role(role, account);
        }

        fn revoke_role(ref self: ContractState, role: u128, account: ContractAddress) {
            AccessControl::revoke_role(role, account);
        }

        fn renounce_role(ref self: ContractState, role: u128) {
            AccessControl::renounce_role(role);
        }

        fn set_pending_admin(ref self: ContractState, new_admin: ContractAddress) {
            AccessControl::set_pending_admin(new_admin);
        }

        fn accept_admin(ref self: ContractState) {
            AccessControl::accept_admin();
        }
    }
}
