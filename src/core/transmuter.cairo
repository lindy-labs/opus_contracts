#[starknet::contract]
mod Transmuter {
    use cmp::min;
    use integer::{BoundedU128, BoundedU256};
    use starknet::{ContractAddress, get_caller_address, get_contract_address};
    use starknet::contract_address::ContractAddressZeroable;

    use opus::core::roles::TransmuterRoles;

    use opus::interfaces::IAbbot::{IAbbotDispatcher, IAbbotDispatcherTrait};
    use opus::interfaces::ICaretaker::{ICaretakerDispatcher, ICaretakerDispatcherTrait};
    use opus::interfaces::IERC20::{IERC20, IERC20Dispatcher, IERC20DispatcherTrait};
    use opus::interfaces::ISentinel::{ISentinelDispatcher, ISentinelDispatcherTrait};
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

    // Note that the debt ceiling for a Transmuter is enforced via the `yang_asset_max`
    // for the Transmuter's dummy token in Sentinel. Therefore, any changes to the 
    // debt ceiling can be made via `Sentinel.set_yang_asset_max`.
    #[storage]
    struct Storage {
        // The Shrine associated with this Transmuter
        shrine: IShrineDispatcher,
        // The Sentinel associated with the Shrine and this Transmuter
        sentinel: ISentinelDispatcher,
        // The Abbot associated with the Shrine and Sentinel
        abbot: IAbbotDispatcher,
        // The Caretaker associated with the Shrine
        caretaker: ICaretakerDispatcher,
        // The asset that can be swapped for yin via this Transmuter
        asset: IERC20Dispatcher,
        // The trove ID representing this Transmuter in Shrine
        trove_id: u64,
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
        // ERC-20
        name: felt252,
        symbol: felt252,
        total_supply: u256,
        balances: LegacyMap::<ContractAddress, u256>,
        allowances: LegacyMap::<(ContractAddress, ContractAddress), u256>,
    }

    //
    // Events
    //

    #[event]
    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    enum Event {
        Initialized: Initialized,
        Killed: Killed,
        CeilingUpdated: CeilingUpdated,
        PercentageCapUpdated: PercentageCapUpdated,
        Transmute: Transmute,
        Reverse: Reverse,
        ReversibilityToggled: ReversibilityToggled,
        ReverseFeeUpdated: ReverseFeeUpdated,
        Sweep: Sweep,
        CaretakerUpdated: CaretakerUpdated,
        ReceiverUpdated: ReceiverUpdated,
        // ERC-20 events
        Transfer: Transfer,
        Approval: Approval,
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct Initialized {
        trove_id: u64,
        ceiling: u128
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
    struct CaretakerUpdated {
        old_caretaker: ContractAddress,
        new_caretaker: ContractAddress
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct ReceiverUpdated {
        old_receiver: ContractAddress,
        new_receiver: ContractAddress
    }

    // ERC-20 events

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct Transfer {
        #[key]
        from: ContractAddress,
        #[key]
        to: ContractAddress,
        value: u256
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct Approval {
        #[key]
        owner: ContractAddress,
        #[key]
        spender: ContractAddress,
        value: u256
    }

    // Constructor

    #[constructor]
    fn constructor(
        ref self: ContractState,
        admin: ContractAddress,
        shrine: ContractAddress,
        sentinel: ContractAddress,
        abbot: ContractAddress,
        caretaker: ContractAddress,
        asset: ContractAddress,
        receiver: ContractAddress,
        percentage_cap: Ray,
        name: felt252,
        symbol: felt252
    ) {
        AccessControl::initializer(admin, Option::Some(TransmuterRoles::default_admin_role()));

        self.shrine.write(IShrineDispatcher { contract_address: shrine });
        self.sentinel.write(ISentinelDispatcher { contract_address: sentinel });
        self.abbot.write(IAbbotDispatcher { contract_address: abbot });
        self.asset.write(IERC20Dispatcher { contract_address: asset });

        self.set_caretaker_helper(caretaker);
        self.set_receiver_helper(receiver);
        self.set_percentage_cap_helper(percentage_cap);

        self.ERC20_initialize(name, symbol);
    }

    #[external(v0)]
    impl ITransmuterImpl of ITransmuter<ContractState> {
        //
        // Getters
        //
        fn get_asset(self: @ContractState) -> ContractAddress {
            self.asset.read().contract_address
        }

        fn get_caretaker(self: @ContractState) -> ContractAddress {
            self.caretaker.read().contract_address
        }

        fn get_trove_id(self: @ContractState) -> u64 {
            self.trove_id.read()
        }

        // Convenience wrapper over `Sentinel.get_yang_asset_max` to perform the necessary conversion
        // between the asset decimals and the dummy token of Wad precision in Shrine
        fn get_ceiling(self: @ContractState) -> u128 {
            let dummy_amt: u128 = self.sentinel.read().get_yang_asset_max(get_contract_address());
            wadray::wad_to_fixed_point(dummy_amt.into(), self.asset.read().decimals())
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

        // This function adds the dummy token of this Transmuter as a yang in Shrine via the Sentinel.
        // Subsequently, it opens a trove with the Abbot to "reserve" a trove ID.
        // Note that this function requires the caller to have approved the Transmuter to transfer
        // such amount of assets equivalent to 1 Wad of dummy tokens.
        fn initialize(ref self: ContractState, gate: ContractAddress, ceiling: u128) -> u64 {
            AccessControl::assert_has_role(TransmuterRoles::INITIALIZE);

            let transmuter: ContractAddress = get_contract_address();

            // Contract needs to be granted permission to call `sentinel.add_yang` beforehand
            self
                .sentinel
                .read()
                .add_yang(
                    transmuter,
                    ceiling,
                    RAY_ONE.into(), // fixed at 100% threshold
                    WAD_ONE.into(), // fixed at 1 USD price
                    RayZeroable::zero(), // fixed at 0% base rate
                    gate,
                    // Since the dummy token will not be circulated except in the event of 
                    // global shutdown, the issue of first depositor front-running in Gate
                    // does not occur. Therefore, the initial yang amount can be set to zero. 
                    Option::Some(0)
                );

            // Set max approval of dummy token in transmuter for gate
            self.approve_helper(transmuter, gate, BoundedU256::max());

            // Transfer asset equivalent to 1 Wad of dummy tokens to transmuter
            let asset_amt: u128 = wadray::wad_to_fixed_point(
                WAD_ONE.into(), self.asset.read().decimals()
            );
            let success: bool = self
                .asset
                .read()
                .transfer_from(get_caller_address(), transmuter, asset_amt.into());

            // Open trove with Abbot
            let trove_id: u64 = self
                .abbot
                .read()
                .open_trove(
                    array![AssetBalance { address: transmuter, amount: WAD_ONE }].span(),
                    WadZeroable::zero(),
                    WadZeroable::zero(),
                );

            self.trove_id.write(trove_id);

            self.emit(Initialized { trove_id, ceiling });

            trove_id
        }

        fn set_caretaker(ref self: ContractState, caretaker: ContractAddress) {
            AccessControl::assert_has_role(TransmuterRoles::SET_CARETAKER);

            self.set_caretaker_helper(caretaker);
        }

        // Convenience wrapper over `Sentinel.set_yang_asset_max` to perform the necessary conversion
        // between the asset decimals and the dummy token of Wad precision in Shrine
        fn set_ceiling(ref self: ContractState, ceiling: u128) {
            AccessControl::assert_has_role(TransmuterRoles::SET_CEILING);

            let sentinel: ISentinelDispatcher = self.sentinel.read();
            let stabilizer: ContractAddress = get_contract_address();
            let old_dummy_amt: u128 = sentinel.get_yang_asset_max(stabilizer);

            let asset_decimals: u8 = self.asset.read().decimals();
            let old_ceiling: u128 = wadray::wad_to_fixed_point(
                old_dummy_amt.into(), asset_decimals
            );

            let new_dummy_amt: Wad = wadray::fixed_point_to_wad(ceiling, asset_decimals);
            sentinel.set_yang_asset_max(stabilizer, new_dummy_amt.val);

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
        // 2. The maximum amount of assets, represented by the dummy token, is exceeded in Sentinel
        fn transmute(ref self: ContractState, asset_amt: u128) {
            let trove_id: u64 = self.trove_id.read();
            assert(trove_id.is_non_zero(), 'TR: Not initialized');

            let asset: IERC20Dispatcher = self.asset.read();
            let dummy_amt: Wad = wadray::fixed_point_to_wad(asset_amt, asset.decimals());
            self.assert_can_transmute(dummy_amt);

            let user: ContractAddress = get_caller_address();
            let transmuter: ContractAddress = get_contract_address();

            // Transfer asset to Transmuter
            let success: bool = asset.transfer_from(user, transmuter, asset_amt.into());
            assert(success, 'TR: Asset transfer failed');

            // Mint equivalent `asset_amt` in dummy tokens to transmuter
            self.mint(transmuter, dummy_amt.into());

            self
                .abbot
                .read()
                .deposit(trove_id, AssetBalance { address: transmuter, amount: dummy_amt.val });

            let shrine: IShrineDispatcher = self.shrine.read();
            shrine.forge(user, trove_id, dummy_amt, Option::None);

            self.emit(Transmute { user, asset_amt, yin_amt: dummy_amt });
        }

        // Swaps yin for the stablecoin asset at a ratio of 1 : 1, scaled down from Wad precision.
        // Reverts if:
        // 1. User has insufficient yin; or
        // 2. Transmuter has insufficent assets corresponding to the burnt yin
        fn reverse(ref self: ContractState, yin_amt: Wad) {
            let trove_id: u64 = self.trove_id.read();
            assert(trove_id.is_non_zero(), 'TR: Not initialized');

            self.assert_reversibility();

            let asset: IERC20Dispatcher = self.asset.read();

            // Burn yin from user
            let user: ContractAddress = get_caller_address();
            let shrine: IShrineDispatcher = self.shrine.read();
            shrine.melt(user, trove_id, yin_amt);

            // Withdraw dummy token from trove and burn
            let transmuter: ContractAddress = get_contract_address();
            let dummy_amt: u128 = self
                .abbot
                .read()
                .withdraw(trove_id, AssetBalance { address: transmuter, amount: yin_amt.val });
            self.burn(transmuter, dummy_amt.into());

            // Transfer asset to user
            let asset_amt: u128 = wadray::wad_to_fixed_point(yin_amt, asset.decimals());
            let fee: u128 = self.get_reverse_fee_helper(asset_amt);

            let user_asset_amt: u128 = asset_amt - fee;
            let success: bool = asset.transfer(user, user_asset_amt.into());
            assert(success, 'TR: Asset transfer failed');

            self.emit(Reverse { user, asset_amt, yin_amt, fee });
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

        // Note that `amount` refers to the dummy token balance that a user would receive
        // via `Caretaker.reclaim`.
        //
        // Note that the amount of asset that can be claimed is no longer pegged 1 : 1
        // because we do not make any assumptions as to the amount of assets held by the 
        // Transmuter.
        fn claim(ref self: ContractState, amount: Wad) {
            assert(self.is_live.read(), 'TR: Transmuter is live');

            let transmuter: ContractAddress = get_contract_address();
            let user: ContractAddress = get_caller_address();

            let asset: IERC20Dispatcher = self.asset.read();
            let asset_balance: u256 = asset.balance_of(transmuter);
            let total_supply: Wad = self.total_supply.read().try_into().unwrap();
            let asset_amt: Wad = (amount / total_supply) * asset_balance.try_into().unwrap();

            self.burn(user, amount.into());
            asset.transfer(user, asset_amt.into());
        }

        // After `Caretaker.shut` is triggered, there will be some amount of dummy tokens
        // remaining in the trove. For example, if 70% of the Shrine's collateral is transferred to the 
        // Caretaker to back circulating yin, then the Transmuter's trove will have 30% of dummy tokens 
        // remaining in its trove. This function sends the amount of assets corresponding to this
        // remainder dummy tokens at the time this function is called to a prescribed address.
        fn extract(ref self: ContractState, recipient: ContractAddress) {
            AccessControl::assert_has_role(TransmuterRoles::EXTRACT);

            assert(self.is_live.read(), 'TR: Transmuter is live');

            let transmuter: ContractAddress = get_contract_address();
            let caretaker: ICaretakerDispatcher = self.caretaker.read();

            let dummy_balance: u256 = self.balances.read(transmuter);

            caretaker.release(self.trove_id.read());
            let updated_dummy_balance: u256 = self.balances.read(transmuter);
            let released_dummy_amt: u256 = updated_dummy_balance - dummy_balance;
            self.burn(transmuter, released_dummy_amt);

            let asset: IERC20Dispatcher = self.asset.read();
            let total_supply: Wad = self.total_supply.read().try_into().unwrap();
            let extract_amt: Wad = (released_dummy_amt.try_into().unwrap() / total_supply)
                * asset.balance_of(transmuter).try_into().unwrap();

            self.asset.read().transfer(recipient, extract_amt.into());
        }
    }

    #[generate_trait]
    impl TransmuterHelpers of TransmuterHelpersTrait {
        // Note that the debt ceiling for a Transmuter is already enforced via the `yang_asset_max`
        // for the Transmuter's dummy token in Sentinel.
        #[inline(always)]
        fn assert_can_transmute(self: @ContractState, amt_to_mint: Wad) {
            let yin_price_ge_peg: bool = self.shrine.read().get_yin_spot_price() >= WAD_ONE.into();

            let cap: Wad = wadray::rmul_wr(
                self.shrine.read().get_total_yin(), self.percentage_cap.read()
            );
            let minted: Wad = self.total_supply.read().try_into().unwrap();
            let is_lt_cap: bool = minted + amt_to_mint <= cap;

            assert(yin_price_ge_peg && is_lt_cap, 'TR: Transmute is paused');
        }

        #[inline(always)]
        fn assert_reversibility(self: @ContractState) {
            assert(self.reversibility.read(), 'TR: Reverse is paused');
        }

        fn set_caretaker_helper(ref self: ContractState, caretaker: ContractAddress) {
            assert(caretaker.is_non_zero(), 'TR: Zero address');
            let old_caretaker: ContractAddress = self.caretaker.read().contract_address;
            self.caretaker.write(ICaretakerDispatcher { contract_address: caretaker });

            self.emit(CaretakerUpdated { old_caretaker, new_caretaker: caretaker });
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

    #[external(v0)]
    impl IERC20Impl of IERC20<ContractState> {
        // ERC20 getters
        fn name(self: @ContractState) -> felt252 {
            self.name.read()
        }

        fn symbol(self: @ContractState) -> felt252 {
            self.symbol.read()
        }

        fn decimals(self: @ContractState) -> u8 {
            WAD_DECIMALS.try_into().unwrap()
        }

        fn total_supply(self: @ContractState) -> u256 {
            self.total_supply.read()
        }

        fn balance_of(self: @ContractState, account: ContractAddress) -> u256 {
            self.balances.read(account)
        }

        fn allowance(
            self: @ContractState, owner: ContractAddress, spender: ContractAddress
        ) -> u256 {
            self.allowances.read((owner, spender))
        }

        // ERC20 public functions
        fn transfer(ref self: ContractState, recipient: ContractAddress, amount: u256) -> bool {
            self.transfer_helper(get_caller_address(), recipient, amount);
            true
        }

        fn transfer_from(
            ref self: ContractState,
            sender: ContractAddress,
            recipient: ContractAddress,
            amount: u256
        ) -> bool {
            self.spend_allowance_helper(sender, get_caller_address(), amount);
            self.transfer_helper(sender, recipient, amount);
            true
        }

        fn approve(ref self: ContractState, spender: ContractAddress, amount: u256) -> bool {
            self.approve_helper(get_caller_address(), spender, amount);
            true
        }
    }

    //
    // Internal ERC20 functions
    //

    #[generate_trait]
    impl ERC20Helpers of ERC20HelpersTrait {
        fn ERC20_initialize(ref self: ContractState, name: felt252, symbol: felt252) {
            self.name.write(name);
            self.symbol.write(symbol);
        }

        fn mint(ref self: ContractState, recipient: ContractAddress, amount: u256) -> bool {
            self.total_supply.write(self.total_supply.read() + amount);
            self.balances.write(recipient, self.balances.read(recipient) + amount);
            self
                .emit(
                    Transfer { from: ContractAddressZeroable::zero(), to: recipient, value: amount }
                );
            true
        }

        fn burn(ref self: ContractState, account: ContractAddress, amount: u256) -> bool {
            self.total_supply.write(self.total_supply.read() - amount);
            self.balances.write(account, self.balances.read(account) - amount);
            self
                .emit(
                    Transfer { from: account, to: ContractAddressZeroable::zero(), value: amount }
                );
            true
        }

        fn transfer_helper(
            ref self: ContractState,
            sender: ContractAddress,
            recipient: ContractAddress,
            amount: u256
        ) {
            assert(recipient.is_non_zero(), 'SH: No transfer to 0 address');

            // Transferring the Yin
            let sender_balance: u256 = self.balances.read(sender);
            assert(sender_balance >= amount, 'SH: Insufficient yin balance');

            self.balances.write(sender, sender_balance - amount);
            self.balances.write(recipient, self.balances.read(recipient) + amount);

            self.emit(Transfer { from: sender, to: recipient, value: amount });
        }

        fn approve_helper(
            ref self: ContractState, owner: ContractAddress, spender: ContractAddress, amount: u256
        ) {
            assert(spender.is_non_zero(), 'SH: No approval of 0 address');
            assert(owner.is_non_zero(), 'SH: No approval for 0 address');

            self.allowances.write((owner, spender), amount);

            self.emit(Approval { owner, spender, value: amount });
        }

        fn spend_allowance_helper(
            ref self: ContractState, owner: ContractAddress, spender: ContractAddress, amount: u256
        ) {
            let current_allowance: u256 = self.allowances.read((owner, spender));

            // if current_allowance is not set to the maximum u256, then
            // subtract `amount` from spender's allowance.
            if current_allowance != BoundedU256::max() {
                assert(current_allowance >= amount, 'SH: Insufficient yin allowance');
                self.approve_helper(owner, spender, current_allowance - amount);
            }
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
