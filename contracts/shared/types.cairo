%lang starknet


struct Trove:
    member last : felt # Timestamp of last accumulated interest calculation
    member debt : felt # Normalized debt
end

struct Gage:
    member total : felt # Total amount of the Gage currently deposited
    member max : felt # Maximum amount of the Gage that can be deposited
    member safety : felt # safety price
end 

struct Point:
    member price : felt 
    member time : felt # timestamp of the price
end