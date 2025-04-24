#[starknet::contract]
pub mod controller {
    use access_control::access_control_component;
    use core::num::traits::{Pow, Sqrt, Zero};
    use opus::core::roles::controller_roles;
    use opus::interfaces::IController::IController;
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
    use starknet::{ContractAddress, get_block_timestamp};
    use wadray::{RAY_ONE, Ray, Signed, SignedRay, Wad, wad_to_signed_ray};

    //
    // Components
    //

    component!(path: access_control_component, storage: access_control, event: AccessControlEvent);

    #[abi(embed_v0)]
    impl AccessControlPublic = access_control_component::AccessControl<ContractState>;
    impl AccessControlHelpers = access_control_component::AccessControlHelpers<ContractState>;

    //
    // Constants
    //

    // Time intervals between updates are scaled down by this factor
    // to prevent the integral term from getting too large
    pub const TIME_SCALE: u128 = 60 * 60; // 60 mins * 60 seconds = 1 hour

    // multiplier bounds (ray)
    pub const MIN_MULTIPLIER: u128 = 200000000000000000000000000; // 0.2
    pub const MAX_MULTIPLIER: u128 = 2000000000000000000000000000; // 2

    //
    // Storage
    //

    #[storage]
    struct Storage {
        // components
        #[substorage(v0)]
        access_control: access_control_component::Storage,
        // Shrine associated with this Controller
        shrine: IShrineDispatcher,
        // parameters
        yin_previous_price: Wad,
        yin_price_last_updated: u64,
        i_term_last_updated: u64,
        // last i_term with gain
        i_term: SignedRay,
        p_gain: SignedRay,
        i_gain: SignedRay,
        alpha_p: u8,
        beta_p: u8,
        alpha_i: u8,
        beta_i: u8,
    }


    #[event]
    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub enum Event {
        AccessControlEvent: access_control_component::Event,
        ParameterUpdated: ParameterUpdated,
        GainUpdated: GainUpdated,
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub struct ParameterUpdated {
        #[key]
        pub name: felt252,
        pub value: u8,
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    pub struct GainUpdated {
        #[key]
        pub name: felt252,
        pub value: Ray,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        admin: ContractAddress,
        shrine: ContractAddress,
        p_gain: Ray,
        i_gain: Ray,
        alpha_p: u8,
        beta_p: u8,
        alpha_i: u8,
        beta_i: u8,
    ) {
        self.access_control.initializer(admin, Option::Some(controller_roles::ADMIN));

        // Setting `i_term_last_updated` to the current timestamp to
        // ensure that the integral term is correctly updated
        self.i_term_last_updated.write(get_block_timestamp());

        // Initializing the previous price to the current price
        // This ensures the integral term is correctly calculated
        let shrine = IShrineDispatcher { contract_address: shrine };
        self.yin_previous_price.write(shrine.get_yin_spot_price());
        self.shrine.write(shrine);

        self.p_gain.write(p_gain.into());
        self.i_gain.write(i_gain.into());
        self.alpha_p.write(alpha_p);
        self.beta_p.write(beta_p);
        self.alpha_i.write(alpha_i);
        self.beta_i.write(beta_i);

        self.emit(GainUpdated { name: 'p_gain', value: p_gain });
        self.emit(GainUpdated { name: 'i_gain', value: i_gain });
        self.emit(ParameterUpdated { name: 'alpha_p', value: alpha_p });
        self.emit(ParameterUpdated { name: 'beta_p', value: beta_p });
        self.emit(ParameterUpdated { name: 'alpha_i', value: alpha_i });
        self.emit(ParameterUpdated { name: 'beta_i', value: beta_i });
    }

    #[abi(embed_v0)]
    impl IControllerImpl of IController<ContractState> {
        // Returns the multiplier value if an update was to be made at the time this was called
        fn get_current_multiplier(self: @ContractState) -> Ray {
            let i_gain = self.i_gain.read();

            let mut multiplier: SignedRay = RAY_ONE.into() + self.get_p_term();

            if i_gain.is_non_zero() {
                let old_i_term = self.i_term.read();
                multiplier += old_i_term;

                // Skip new i_term if timestamp did not advance from the last i_term
                if get_block_timestamp() > self.i_term_last_updated.read() {
                    multiplier += i_gain * self.get_i_term_without_gain();
                }
            }

            bound_multiplier(multiplier).try_into().unwrap()
        }


        fn get_p_term(self: @ContractState) -> SignedRay {
            self.p_gain.read() * nonlinear_transform(self.get_current_error(), self.alpha_p.read(), self.beta_p.read())
        }


        fn get_i_term(self: @ContractState) -> SignedRay {
            let i_gain = self.i_gain.read();
            if i_gain.is_zero() {
                Zero::zero()
            } else {
                i_gain * self.get_i_term_without_gain()
            }
        }


        fn get_parameters(self: @ContractState) -> ((SignedRay, SignedRay), (u8, u8, u8, u8)) {
            (
                (self.p_gain.read(), self.i_gain.read()),
                (self.alpha_p.read(), self.beta_p.read(), self.alpha_i.read(), self.beta_i.read()),
            )
        }


        fn update_multiplier(ref self: ContractState) {
            let shrine: IShrineDispatcher = self.shrine.read();

            let i_gain = self.i_gain.read();
            let mut multiplier: SignedRay = RAY_ONE.into() + self.get_p_term();

            // Only updating the integral term and adding it to the multiplier if the integral gain is non-zero
            if i_gain.is_non_zero() {
                let old_i_term = self.i_term.read();
                multiplier += old_i_term;

                // Skip new i_term if timestamp did not advance from the last i_term
                // to avoid overwriting the previous i_term
                if get_block_timestamp() > self.i_term_last_updated.read() {
                    let new_i_term_without_gain: SignedRay = self.get_i_term_without_gain();
                    let new_i_term_with_gain: SignedRay = i_gain * new_i_term_without_gain;
                    multiplier += new_i_term_with_gain;
                    self.i_term.write(new_i_term_with_gain);
                    self.i_term_last_updated.write(get_block_timestamp());
                }
            }

            // Updating the previous yin price for the next integral term update
            self.yin_previous_price.write(shrine.get_yin_spot_price());

            let multiplier_ray: Ray = bound_multiplier(multiplier).try_into().unwrap();
            shrine.set_multiplier(multiplier_ray);
        }


        fn set_p_gain(ref self: ContractState, p_gain: Ray) {
            self.access_control.assert_has_role(controller_roles::TUNE_CONTROLLER);
            self.p_gain.write(p_gain.into());
            self.emit(GainUpdated { name: 'p_gain', value: p_gain });
        }


        fn set_i_gain(ref self: ContractState, i_gain: Ray) {
            self.access_control.assert_has_role(controller_roles::TUNE_CONTROLLER);

            // Since `i_term_last_updated` is not updated in `update_multiplier`
            // while `i_gain` is zero, we must update it here whenever the
            // `i_gain` is set from zero to a non-zero value in order to ensure
            // that the accumulation of the integral term starts at zero.
            // Note that although `i_term_last_updated` is also updated in the case
            // where `i_gain` gets set from zero to zero, this would not be an issue
            // anyway because the i_term would not be calculated if `i_gain` is zero.
            if self.i_gain.read().is_zero() {
                self.i_term_last_updated.write(get_block_timestamp());
            }

            // Reset the integral term if the i_gain is set to zero
            if i_gain.is_zero() {
                self.i_term.write(Zero::zero());
            }

            self.i_gain.write(i_gain.into());
            self.emit(GainUpdated { name: 'i_gain', value: i_gain });
        }


        fn set_alpha_p(ref self: ContractState, alpha_p: u8) {
            self.access_control.assert_has_role(controller_roles::TUNE_CONTROLLER);
            assert(alpha_p % 2 == 1, 'CTR: alpha_p must be odd');
            self.alpha_p.write(alpha_p);
            self.emit(ParameterUpdated { name: 'alpha_p', value: alpha_p });
        }


        fn set_beta_p(ref self: ContractState, beta_p: u8) {
            self.access_control.assert_has_role(controller_roles::TUNE_CONTROLLER);
            assert(beta_p % 2 == 0, 'CTR: beta_p must be even');
            self.beta_p.write(beta_p);
            self.emit(ParameterUpdated { name: 'beta_p', value: beta_p });
        }


        fn set_alpha_i(ref self: ContractState, alpha_i: u8) {
            self.access_control.assert_has_role(controller_roles::TUNE_CONTROLLER);
            assert(alpha_i % 2 == 1, 'CTR: alpha_i must be odd');
            self.alpha_i.write(alpha_i);
            self.emit(ParameterUpdated { name: 'alpha_i', value: alpha_i });
        }


        fn set_beta_i(ref self: ContractState, beta_i: u8) {
            self.access_control.assert_has_role(controller_roles::TUNE_CONTROLLER);
            assert(beta_i % 2 == 0, 'CTR: beta_i must be even');
            self.beta_i.write(beta_i);
            self.emit(ParameterUpdated { name: 'beta_i', value: beta_i });
        }
    }

    #[generate_trait]
    impl ControllerInternalFunctions of ControllerInternalFunctionsTrait {
        #[inline(always)]
        fn get_i_term_without_gain(self: @ContractState) -> SignedRay {
            let current_timestamp: u64 = get_block_timestamp();

            let time_since_last_update: u128 = (current_timestamp - self.i_term_last_updated.read()).into();
            let time_since_last_update_scaled: SignedRay = (time_since_last_update * RAY_ONE).into()
                / (TIME_SCALE * RAY_ONE).into();

            nonlinear_transform(self.get_prev_error(), self.alpha_i.read(), self.beta_i.read())
                * time_since_last_update_scaled
        }

        #[inline(always)]
        fn get_current_error(self: @ContractState) -> SignedRay {
            RAY_ONE.into() - wad_to_signed_ray(self.shrine.read().get_yin_spot_price())
        }

        // Returns the error at the time of the last update to the multiplier
        #[inline(always)]
        fn get_prev_error(self: @ContractState) -> SignedRay {
            RAY_ONE.into() - wad_to_signed_ray(self.yin_previous_price.read())
        }
    }

    // Pure functions

    #[inline(always)]
    fn nonlinear_transform(error: SignedRay, alpha: u8, beta: u8) -> SignedRay {
        let error_ray: Ray = if error.is_negative() {
            (-error).try_into().unwrap()
        } else {
            error.try_into().unwrap()
        };
        let denominator: SignedRay = Sqrt::sqrt(RAY_ONE.into() + error_ray.pow(beta.into())).into();
        error.pow(alpha.into()) / denominator
    }

    #[inline(always)]
    fn bound_multiplier(multiplier: SignedRay) -> SignedRay {
        if multiplier > MAX_MULTIPLIER.into() {
            MAX_MULTIPLIER.into()
        } else if multiplier < MIN_MULTIPLIER.into() {
            MIN_MULTIPLIER.into()
        } else {
            multiplier
        }
    }
}
