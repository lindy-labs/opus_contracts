from event_converter import convert_events
from storage_converter import convert_storage

input_contract = "absorber.cairo"
output_contract = "converted_absorber.cairo"

with open(input_contract, "r") as f:
    contract = f.read()

updated_contract = convert_storage(convert_events(contract))

with open(output_contract, "w") as f:
    f.write(updated_contract)
