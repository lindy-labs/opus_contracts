namespace GateRoles:
    #
    # Roles
    #
    const DEPOSIT = 2 ** 0
    const KILL = 2 ** 1
    const SET_TAX = 2 ** 2
    const SET_TAX_COLLECTOR = 2 ** 3
    const WITHDRAW = 2 ** 4

    #
    # Constants
    #
    const DEFAULT_GATE_ADMIN_ROLE = KILL
    const DEFAULT_GATE_TAXABLE_ADMIN_ROLE = KILL + SET_TAX + SET_TAX_COLLECTOR
end
