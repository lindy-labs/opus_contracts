#[contract]
mod Controller {
    use option::OptionTrait;
    use starknet::{ContractAddress, contract_address, get_block_timestamp};
    use traits::{Into, TryInto};
    use zeroable::Zeroable;

    use aura::core::roles::ControllerRoles;

    use aura::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use aura::utils::access_control::AccessControl;
    use aura::utils::math;
    use aura::utils::wadray;
    use aura::utils::wadray::{Wad, Ray, RAY_ONE};
    use aura::utils::wadray_signed;
    use aura::utils::wadray_signed::{SignedRay, SignedRayZeroable};

    // Time intervals between updates are scaled down by this factor 
    // to prevent the integral term from getting too large
    const TIME_SCALE: u128 = 3600; // 60 mins * 60 seconds = 1 hour

    // multiplier bounds (ray)
    const MIN_MULTIPLIER: u128 = 200000000000000000000000000; // 0.2
    const MAX_MULTIPLIER: u128 = 2000000000000000000000000000; // 2

    struct Storage {
        shrine: IShrineDispatcher,
        yin_previous_price: Wad,
        yin_price_last_updated: u64,
        i_term_last_updated: u64,
        i_term: SignedRay,
        p_gain: SignedRay,
        i_gain: SignedRay,
        alpha_p: u8,
        beta_p: u8,
        alpha_i: u8,
        beta_i: u8,
    }

    #[event]
    fn ParameterUpdated(name: felt252, value: u8) {}

    #[event]
    fn GainUpdated(name: felt252, value: Ray) {}

    #[constructor]
    fn constructor(
        admin: ContractAddress,
        shrine: ContractAddress,
        p_gain: Ray,
        i_gain: Ray,
        alpha_p: u8,
        beta_p: u8,
        alpha_i: u8,
        beta_i: u8,
    ) {
        AccessControl::initializer(admin);
        AccessControl::grant_role_internal(ControllerRoles::TUNE_CONTROLLER, admin);

        // Setting `i_term_last_updated` to the current timestamp to 
        // ensure that the integral term is correctly updated
        i_term_last_updated::write(get_block_timestamp());

        // Initializing the previous price to the current price
        // This ensures the integral term is correctly calculated
        let shrine = IShrineDispatcher { contract_address: shrine };
        yin_previous_price::write(shrine.get_yin_spot_price());
        shrine::write(shrine);

        p_gain::write(p_gain.into());
        i_gain::write(i_gain.into());
        alpha_p::write(alpha_p);
        beta_p::write(beta_p);
        alpha_i::write(alpha_i);
        beta_i::write(beta_i);

        GainUpdated('p_gain', p_gain);
        GainUpdated('i_gain', i_gain);
        ParameterUpdated('alpha_p', alpha_p);
        ParameterUpdated('beta_p', beta_p);
        ParameterUpdated('alpha_i', alpha_i);
        ParameterUpdated('beta_i', beta_i);
    }

    //
    // View functions 
    // 

    #[view]
    fn get_current_multiplier() -> Ray {
        let i_gain = i_gain::read();

        let mut multiplier: SignedRay = RAY_ONE.into() + get_p_term_internal();

        if i_gain.is_non_zero() {
            let new_i_term: SignedRay = get_i_term_internal();
            multiplier += i_gain * new_i_term;
        }

        bound_multiplier(multiplier).try_into().unwrap()
    }

    #[view]
    fn get_p_term() -> SignedRay {
        get_p_term_internal()
    }

    #[view]
    fn get_i_term() -> SignedRay {
        let i_gain = i_gain::read();
        if i_gain.is_zero() {
            SignedRayZeroable::zero()
        } else {
            i_gain * get_i_term_internal()
        }
    }

    #[view]
    fn get_parameters() -> ((SignedRay, SignedRay), (u8, u8, u8, u8)) {
        (
            (p_gain::read(), i_gain::read()),
            (alpha_p::read(), beta_p::read(), alpha_i::read(), beta_i::read())
        )
    }

    // 
    // External 
    // 
    #[external]
    fn update_multiplier() {
        let shrine: IShrineDispatcher = shrine::read();

        let i_gain = i_gain::read();
        let mut multiplier: SignedRay = RAY_ONE.into() + get_p_term_internal();

        // Only updating the integral term and adding it to the multiplier if the integral gain is non-zero
        if i_gain.is_non_zero() {
            let new_i_term: SignedRay = get_i_term_internal();
            multiplier += i_gain * new_i_term;
            i_term::write(new_i_term);
            i_term_last_updated::write(get_block_timestamp());
        }

        // Updating the previous yin price for the next integral term update 
        yin_previous_price::write(shrine.get_yin_spot_price().into());

        let multiplier_ray: Ray = bound_multiplier(multiplier).try_into().unwrap();
        shrine.set_multiplier(multiplier_ray);
    }

    #[external]
    fn set_p_gain(p_gain: Ray) {
        AccessControl::assert_has_role(ControllerRoles::TUNE_CONTROLLER);
        p_gain::write(p_gain.into());
        GainUpdated('p_gain', p_gain);
    }

    #[external]
    fn set_i_gain(i_gain: Ray) {
        AccessControl::assert_has_role(ControllerRoles::TUNE_CONTROLLER);

        // Since `i_term_last_updated` isn't updated in `update_multiplier` 
        // while `i_gain` is zero, we must update it here whenever the 
        // `i_gain` is set from zero to a non-zero value in order to ensure 
        // that the accumulation of the integral term starts at zero. 
        if i_gain::read().is_zero() {
            i_term_last_updated::write(get_block_timestamp());
        }

        // Reset the integral term if the i_gain is set to zero
        if i_gain.is_zero() {
            i_term::write(SignedRayZeroable::zero());
        }

        i_gain::write(i_gain.into());
        GainUpdated('i_gain', i_gain);
    }

    #[external]
    fn set_alpha_p(alpha_p: u8) {
        AccessControl::assert_has_role(ControllerRoles::TUNE_CONTROLLER);
        assert(alpha_p % 2 == 1, 'CTR: alpha_p must be odd');
        alpha_p::write(alpha_p);
        ParameterUpdated('alpha_p', alpha_p);
    }

    #[external]
    fn set_beta_p(beta_p: u8) {
        AccessControl::assert_has_role(ControllerRoles::TUNE_CONTROLLER);
        assert(beta_p % 2 == 0, 'CTR: beta_p must be even');
        beta_p::write(beta_p);
        ParameterUpdated('beta_p', beta_p);
    }

    #[external]
    fn set_alpha_i(alpha_i: u8) {
        AccessControl::assert_has_role(ControllerRoles::TUNE_CONTROLLER);
        assert(alpha_i % 2 == 1, 'CTR: alpha_i must be odd');
        alpha_i::write(alpha_i);
        ParameterUpdated('alpha_i', alpha_i);
    }

    #[external]
    fn set_beta_i(beta_i: u8) {
        AccessControl::assert_has_role(ControllerRoles::TUNE_CONTROLLER);
        assert(beta_i % 2 == 0, 'CTR: beta_i must be even');
        beta_i::write(beta_i);
        ParameterUpdated('beta_i', beta_i);
    }

    // 
    // Internal functions 
    //

    #[inline(always)]
    fn get_p_term_internal() -> SignedRay {
        p_gain::read() * nonlinear_transform(get_current_error(), alpha_p::read(), beta_p::read())
    }

    #[inline(always)]
    fn get_i_term_internal() -> SignedRay {
        let current_timestamp: u64 = get_block_timestamp();
        let old_i_term = i_term::read();

        let time_since_last_update: u128 = (current_timestamp - i_term_last_updated::read()).into();
        let time_since_last_update_scaled: SignedRay = (time_since_last_update * RAY_ONE).into()
            / (TIME_SCALE * RAY_ONE).into();

        old_i_term
            + nonlinear_transform(get_prev_error(), alpha_i::read(), beta_i::read())
                * time_since_last_update_scaled
    }

    #[inline(always)]
    fn nonlinear_transform(error: SignedRay, alpha: u8, beta: u8) -> SignedRay {
        let error_ray: Ray = Ray { val: error.val };
        let denominator: SignedRay = math::sqrt(RAY_ONE.into() + math::pow(error_ray, beta)).into();
        math::pow(error, alpha) / denominator
    }

    #[inline(always)]
    fn get_current_error() -> SignedRay {
        RAY_ONE.into() - shrine::read().get_yin_spot_price().into()
    }

    // Returns the error at the time of the last update to the multiplier
    #[inline(always)]
    fn get_prev_error() -> SignedRay {
        RAY_ONE.into() - yin_previous_price::read().into()
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


    //
    // Public AccessControl functions
    //

    #[view]
    fn get_roles(account: ContractAddress) -> u128 {
        AccessControl::get_roles(account)
    }

    #[view]
    fn has_role(role: u128, account: ContractAddress) -> bool {
        AccessControl::has_role(role, account)
    }

    #[view]
    fn get_admin() -> ContractAddress {
        AccessControl::get_admin()
    }

    #[view]
    fn get_pending_admin() -> ContractAddress {
        AccessControl::get_pending_admin()
    }

    #[external]
    fn grant_role(role: u128, account: ContractAddress) {
        AccessControl::grant_role(role, account);
    }

    #[external]
    fn revoke_role(role: u128, account: ContractAddress) {
        AccessControl::revoke_role(role, account);
    }

    #[external]
    fn renounce_role(role: u128) {
        AccessControl::renounce_role(role);
    }

    #[external]
    fn set_pending_admin(new_admin: ContractAddress) {
        AccessControl::set_pending_admin(new_admin);
    }

    #[external]
    fn accept_admin() {
        AccessControl::accept_admin();
    }
}