%lang starknet

from starkware.cairo.common.cairo_builtins import HashBuiltin

from contracts.lib.int125.Int125 import Int125

# implementation of the Model Reference Adaptive Control controller
# section 4.8 of the Whitepaper

# TODO: better comments

const SCALE = 10 ** 18

struct Parameters:
    # interest rate
    member u : Int125.Int
    # reference rate
    member r : Int125.Int
    # collaterization ratio
    member y : Int125.Int

    # tuning parameters
    member theta : Int125.Int
    member theta_underline : Int125.Int
    member theta_bar : Int125.Int
    member gamma : Int125.Int
    member T : Int125.Int

    # the whitepaper also references "epsilon" tuning parameter
    # but it is not used in the update law formula
end

#
# EVENTS
#

@event
func Parameters_changed(params : Parameters):
end

#
# STORAGE
#

@storage_var
func parameters() -> (params : Parameters):
end

#
# FUNCTIONS
#

# TODO: ownable or some kind of auth, apply the check to the contract
@constructor
func constructor{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
        params : Parameters):
    # params must be scaled by SCALE
    # TODO: do a check for it? how?
    parameters.write(params)
    Parameters_changed.emit(params)

    return ()
end

@view
func get_parameters{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (
        parameters : Parameters):
    let (params) = parameters.read()
    return (params)
end

@external
func adjust_parameters{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
        new_r : felt, new_theta_underline : felt, new_theta_bar : felt, new_gamma : felt,
        new_T : felt):
    # TODO: check if the new_params are already scaled?
    let (params) = parameters.read()
    let new_params = Parameters(
        u=params.u,
        r=Int125.Int(new_r),
        y=params.y,
        theta=params.theta,
        theta_underline=Int125.Int(new_theta_underline),
        theta_bar=Int125.Int(new_theta_bar),
        gamma=Int125.Int(new_gamma),
        T=Int125.Int(new_T))

    parameters.write(new_params)
    Parameters_changed.emit(new_params)

    return ()
end

# implementation of the update law (23)
# u(k) = theta(k)
# theta(k+1) = theta(k) + T * gamma * (theta(k) - theta_underline(k)) * (theta_bar(k) - theta(k)) * (r(k) - y(k))
func calculate_new_parameters{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
        params : Parameters, new_util_rate : felt) -> (params : Parameters):
    let new_y = Int125.Int(new_util_rate * SCALE)

    let (Tg) = Int125_mul_scaled(params.T, params.gamma)
    let (theta1, _) = Int125.sub(params.theta, params.theta_underline)
    let (Tg_t1) = Int125_mul_scaled(Tg, theta1)
    let (theta2, _) = Int125.sub(params.theta_bar, params.theta)
    let (Tg_t1_t2) = Int125_mul_scaled(Tg_t1, theta2)
    let (r_sub_y, _) = Int125.sub(params.r, new_y)

    let (prod) = Int125_mul_scaled(Tg_t1_t2, r_sub_y)

    let (new_theta, _) = Int125.add(params.theta, prod)

    let new_params = Parameters(
        u=new_theta,
        r=params.r,
        y=new_y,
        theta=new_theta,
        theta_underline=params.theta_underline,
        theta_bar=params.theta_bar,
        gamma=params.gamma,
        T=params.T)

    return (new_params)
end

# multiply and descale, unchecked
func Int125_mul_scaled{range_check_ptr}(a : Int125.Int, b : Int125.Int) -> (product : Int125.Int):
    let (m, _) = Int125.mul(a, b)
    let (s, _) = Int125.div_rem(m, Int125.Int(SCALE))
    return (s)
end
