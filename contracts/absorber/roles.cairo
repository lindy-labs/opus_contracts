namespace AbsorberRoles {
    //
    // Roles
    //
    const ADD_BLESSING = 2 ** 0;
    const COMPENSATE = 2 ** 1;
    const KILL = 2 ** 2;
    const SET_PURGER = 2 ** 3;
    const UPDATE = 2 ** 4;

    const DEFAULT_ABSORBER_ADMIN_ROLE = ADD_BLESSING + KILL + SET_PURGER;
}
