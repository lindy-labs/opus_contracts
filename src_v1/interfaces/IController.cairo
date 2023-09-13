use starknet::ContractAddress;

use aura::utils::wadray::Ray;
use aura::utils::wadray_signed::SignedRay;

#[abi]
trait IController {
    // View Functions
    fn get_current_multiplier() -> Ray;
    fn get_p_term() -> SignedRay;
    fn get_i_term() -> SignedRay;
    fn get_parameters() -> ((SignedRay, SignedRay), (u8, u8, u8, u8));

    // External Functions
    fn update_multiplier();
    fn set_p_gain(p_gain: Ray);
    fn set_i_gain(i_gain: Ray);
    fn set_alpha_p(alpha_p: u8);
    fn set_beta_p(beta_p: u8);
    fn set_alpha_i(alpha_i: u8);
    fn set_beta_i(beta_i: u8);
}
