#[contract]
mod Controller {
    use aura::core::roles::ControllerRoles;

    use aura::utils::access_control::AccessControl;
    use aura::utils::wadray;
    use aura::utils::wadray::{Wad, Ray};

    struct Storage {
        integral_sum: Wad,
        current_yin_price: Wad,
        yin_price_last_updated: u64,
        p_gain: Ray,
        i_gain: Ray,
    }

    fn constructor(admin: ContractAddress, p_gain: Ray, i_gain: Ray) {
        AccessControl::initializer(admin);
        AccessControl::grant_role_internal(ControllerRoles::TUNE_CONTROLLER, admin);

        p_gain::write(p_gain);
        i_gain::write(i_gain);
    }

    #[view]
    fn get_p_gain() -> Ray {
        p_gain::read()
    }

    #[view]
    fn get_i_gain() -> Ray {
        i_gain::read()
    }


    #[external]
    fn set_p_gain(p_gain: Ray) {
        AccessControl::assert_has_role(ControllerRoles::TUNE_CONTROLLER);
        p_gain::write(p_gain);
    }

    #[external]
    fn set_i_gain(i_gain: Ray) {
        AccessControl::assert_has_role(ControllerRoles::TUNE_CONTROLLER);
        i_gain::write(i_gain);
    }

    #[view]
    fn get_current_multiplier() -> Ray {
        let p_gain = p_gain::read();
        let current_yin_price = current_yin_price::read();
    }
}
