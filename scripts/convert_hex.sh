#!/bin/bash

# Use "$@" to capture all arguments and execute them as a command
"$@" | while IFS= read -r line; do
  # Initialize an empty string to hold the modified line
  modified_line=""
  
  # Split the line by spaces and process each word
  IFS=' ' read -ra words <<< "$line"
  for word in "${words[@]}"; do
    # If the word is a hex number, convert it to decimal using Python
    if [[ $word =~ ^0x[0-9a-fA-F]+$ ]]; then
      decimal=$(python -c "print(int('$word', 16))")
      modified_line+="$decimal"
    else
      modified_line+="$word"
    fi
    modified_line+=" "  # Add a space after each word
  done
  
  # Remove the trailing space and print the modified line
  echo "${modified_line%?}"
done
