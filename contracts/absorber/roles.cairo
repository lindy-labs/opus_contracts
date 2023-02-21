namespace AbsorberRoles {
    //
    // Roles
    //
    const COMPENSATE = 2 ** 0;
    const KILL = 2 ** 1;
    const SET_PURGER = 2 ** 2;
    const SET_REWARD = 2 ** 3;
    const UPDATE = 2 ** 4;

    const DEFAULT_ABSORBER_ADMIN_ROLE = KILL + SET_PURGER + SET_REWARD;
}

namespace BlesserRoles {
    const BLESS = 2 ** 0;
}
