#[starknet::contract]
mod Transmuter {
    use cmp::min;
    use starknet::{ContractAddress, get_caller_address, get_contract_address};

    use opus::core::roles::TransmuterRoles;

    use opus::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::interfaces::ITransmuter::ITransmuter;
    use opus::types::AssetBalance;
    use opus::utils::access_control::{AccessControl, IAccessControl};
    use opus::utils::wadray;
    use opus::utils::wadray::{Ray, Wad, WAD_ONE};

    //
    // Constants
    //

    // Upper bound of the maximum amount of yin that can be minted via this Transmuter as a 
    // percentage of total yin supply: 10% (Ray)
    const PERCENTAGE_CAP_UPPER_BOUND: u128 = 100000000000000000000000000;

    // Upper bound of the fee as a percentage that can be charged for both: 1% (Ray)
    // 1. swapping yin for the asset when `reverse` is enabled; and
    // 2. swapping assett for yin,
    // This is not set at deployment so it defaults to 0%.
    const FEE_UPPER_BOUND: u128 = 10000000000000000000000000;

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
        // Fee to be charged for each `transmute` transaction
        transmute_fee: Ray,
        // Keeps track of whether the Transmuter is live or killed
        is_live: bool,
        // Keeps track of whether `reclaim` has started after Transmuter is killed
        is_reclaimable: bool,
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
        TransmuteFeeUpdated: TransmuteFeeUpdated,
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
    struct TransmuteFeeUpdated {
        old_fee: Ray,
        new_fee: Ray
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

        // Reversibility is enabled at deployment
        self.reversibility.write(true);
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

        fn get_transmute_fee(self: @ContractState) -> Ray {
            self.transmute_fee.read()
        }

        fn get_reverse_fee(self: @ContractState) -> Ray {
            self.reverse_fee.read()
        }

        fn get_live(self: @ContractState) -> bool {
            self.is_live.read()
        }

        fn get_reclaimable(self: @ContractState) -> bool {
            self.is_reclaimable.read()
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

        fn set_transmute_fee(ref self: ContractState, fee: Ray) {
            AccessControl::assert_has_role(TransmuterRoles::SET_FEES);

            assert(fee <= FEE_UPPER_BOUND.into(), 'TR: Exceeds max fee');
            let old_fee: Ray = self.transmute_fee.read();
            self.transmute_fee.write(fee);

            self.emit(TransmuteFeeUpdated { old_fee, new_fee: fee });
        }

        fn set_reverse_fee(ref self: ContractState, fee: Ray) {
            AccessControl::assert_has_role(TransmuterRoles::SET_FEES);

            assert(fee <= FEE_UPPER_BOUND.into(), 'TR: Exceeds max fee');
            let old_fee: Ray = self.reverse_fee.read();
            self.reverse_fee.write(fee);

            self.emit(ReverseFeeUpdated { old_fee, new_fee: fee });
        }

        // One way function to enable `reclaim` after Transmuter is killed.
        // This should be called after the assets backing the total transmuted amount
        //  has been transferred back to the  Transmuter after shutdown.
        fn enable_reclaim(ref self: ContractState) {
            AccessControl::assert_has_role(TransmuterRoles::ENABLE_RECLAIM);

            assert(!self.is_live.read(), 'TR: Transmuter is live');
            self.is_reclaimable.write(true);
        }

        // 
        // Core functions - View
        //

        // Returns the amount of yin that a user will receive for the given asset amount
        // based on current on-chain conditions
        fn preview_transmute(self: @ContractState, asset_amt: u128) -> Wad {
            self.assert_live();

            let asset: IERC20Dispatcher = self.asset.read();
            let fee: u128 = wadray::rmul_wr(asset_amt.into(), self.reverse_fee.read()).val;
            let asset_amt_to_transmute: u128 = asset_amt - fee;
            let yin_amt: Wad = wadray::fixed_point_to_wad(asset_amt_to_transmute, asset.decimals());
            self.assert_can_transmute(yin_amt);

            yin_amt
        }

        // Returns the amount of stablecoin asset that a user will receive for the given yin amount
        // based on current on-chain conditions.
        // Note that it does not guarantee the Transmuter has sufficient asset for reverse.
        fn preview_reverse(self: @ContractState, yin_amt: Wad) -> u128 {
            let (asset_amt, _) = self.preview_reverse_helper(yin_amt);
            asset_amt
        }

        //
        // Core functions - External
        //

        // Deducts the transmute fee, if any, from the asset amount to be transmuted,
        // and converts the remainder to yin at a ratio of 1 : 1, scaled to Wad precision.
        // Reverts if:
        // 1. User has insufficent assets; or
        // 2. Ceiling will be exceeded
        fn transmute(ref self: ContractState, asset_amt: u128) {
            self.assert_live();

            let asset: IERC20Dispatcher = self.asset.read();
            let yin_amt: Wad = self.preview_transmute(asset_amt);

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
            self.assert_live();

            assert(self.reversibility.read(), 'TR: Reverse is paused');

            let (asset_amt, fee) = self.preview_reverse_helper(yin_amt);

            // Decrement total transmuted amount by yin amount
            self.total_transmuted.write(self.total_transmuted.read() - yin_amt);

            // Burn yin from user
            let user: ContractAddress = get_caller_address();
            self.shrine.read().eject(user, yin_amt);

            // Transfer asset to user
            // Since the fee is excluded, it is automatically retained in the Transmuter's balance.
            let success: bool = self.asset.read().transfer(user, asset_amt.into());
            assert(success, 'TR: Asset transfer failed');

            self.emit(Reverse { user, asset_amt, yin_amt, fee });
        }

        // Transfers assets in the transmuter to the receiver
        fn sweep(ref self: ContractState, asset_amt: u128) {
            self.assert_live();

            AccessControl::assert_has_role(TransmuterRoles::SWEEP);

            let asset: IERC20Dispatcher = self.asset.read();
            let asset_balance: u128 = asset.balance_of(get_contract_address()).try_into().unwrap();
            let capped_asset_amt: u128 = min(asset_balance, asset_amt);

            let recipient: ContractAddress = self.receiver.read();
            asset.transfer(recipient, capped_asset_amt.into());

            self.emit(Sweep { recipient, asset_amt: capped_asset_amt });
        }

        //
        // Shutdown
        //

        fn kill(ref self: ContractState) {
            AccessControl::assert_has_role(TransmuterRoles::KILL);
            self.is_live.write(false);
            self.emit(Killed {});
        }

        fn preview_reclaim(self: @ContractState, yin: Wad) -> u128 {
            assert(self.is_reclaimable.read(), 'TR: Reclaim unavailable');

            let asset_balance: Wad = self
                .asset
                .read()
                .balance_of(get_contract_address())
                .try_into()
                .unwrap();

            ((yin / self.total_transmuted.read()) * asset_balance).val
        }

        // Note that the amount of asset that can be claimed is no longer pegged 1 : 1
        // because we do not make any assumptions as to the amount of assets held by the 
        // Transmuter.
        fn reclaim(ref self: ContractState, yin: Wad) {
            assert(self.is_reclaimable.read(), 'TR: Reclaim unavailable');

            let asset_amt: u128 = self.preview_reclaim(yin);

            self.total_transmuted.write(self.total_transmuted.read() - yin);
            let caller: ContractAddress = get_caller_address();
            self.shrine.read().eject(caller, yin);
            self.asset.read().transfer(caller, asset_amt.into());
        }
    }

    #[generate_trait]
    impl TransmuterHelpers of TransmuterHelpersTrait {
        #[inline(always)]
        fn assert_live(self: @ContractState) {
            assert(self.is_live.read(), 'TR: Transmuter is not live');
        }

        #[inline(always)]
        fn assert_can_transmute(self: @ContractState, amt_to_mint: Wad) {
            let shrine: IShrineDispatcher = self.shrine.read();
            let yin_price_ge_peg: bool = shrine.get_yin_spot_price() >= WAD_ONE.into();

            let cap: Wad = wadray::rmul_wr(shrine.get_total_yin(), self.percentage_cap.read());
            let minted: Wad = self.total_transmuted.read();
            let is_lt_cap: bool = minted + amt_to_mint <= cap;

            assert(yin_price_ge_peg && is_lt_cap, 'TR: Transmute is paused');
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

        fn preview_reverse_helper(self: @ContractState, yin_amt: Wad) -> (u128, u128) {
            self.assert_live();

            assert(self.reversibility.read(), 'TR: Reverse is paused');

            let asset: IERC20Dispatcher = self.asset.read();
            let asset_amt: u128 = wadray::wad_to_fixed_point(yin_amt, asset.decimals());
            let fee: u128 = wadray::rmul_wr(asset_amt.into(), self.reverse_fee.read()).val;

            (asset_amt, fee)
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
