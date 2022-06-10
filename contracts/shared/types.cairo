%lang starknet


struct Trove:
    member last : felt # Time ID (timestamp // TIME_ID_INTERVAL) of last accumulated interest calculation
    member debt : felt # Normalized debt
end

struct Gage:
    member total : felt # Total amount of the Gage currently deposited
    member max : felt # Maximum amount of the Gage that can be deposited
end 

struct Point:
    member val : felt 
    member time : felt # timestamp of the price
end