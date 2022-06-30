%lang starknet

struct Trove:
    member charge_from : felt  # Time ID (timestamp // TIME_ID_INTERVAL) for start of next accumulated interest calculation
    member debt : felt  # Normalized debt
end

struct Yang:
    member total : felt  # Total amount of the Gage currently deposited
    member max : felt  # Maximum amount of the Gage that can be deposited
end
