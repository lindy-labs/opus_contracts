namespace GateRoles:
    #
    # Roles
    #
    const KILL = 2 ** 0
    const DEPOSIT = 2 ** 1
    const WITHDRAW = 2 ** 2
    const SET_TAX = 2 ** 3
    const SET_TAX_COLLECTOR = 2 ** 4

    #
    # Constants
    #
    const DEFAULT_GATE_ADMIN_ROLE = KILL
    const DEFAULT_GATE_TAXABLE_ADMIN_ROLE = KILL + SET_TAX + SET_TAX_COLLECTOR
end
