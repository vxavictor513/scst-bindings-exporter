#!/usr/bin/env bash

# Script to convert specific JSON structure to CSV
# Requires 'jq' (install on macOS: brew install jq)

# Check if jq is installed
if ! command -v jq &> /dev/null; then
    echo "Error: jq is not installed." >&2
    echo "Please install jq using Homebrew: brew install jq" >&2
    exit 1
fi

# --- Configuration ---
# Define the header row for the CSV output
HEADER="deployment,bindingName,topicName,concurrency,maxAttempts,backOffInitialInterval,backOffMaxInterval,backOffMultiplier,enableDlq,dlqName,max.poll.interval.ms,max.poll.records"

# --- Main Logic ---

# Print the header row
echo "$HEADER"

# Process the JSON from standard input using jq
# -r outputs raw strings (removes quotes from CSV output)
# The jq filter:
# .[]                  # Iterate over the top-level array elements
# | .deployment as $dep # Store the deployment name in a variable $dep
# | .bindings[]        # Iterate over the bindings array for each deployment
# | [...] | @csv       # Create an array of the desired fields and format as CSV
# // ""                # Provide an empty string default for potentially null/missing values
jq -r '
.[] | .deployment as $dep | .bindings[] | [
    $dep,
    .bindingName,
    .name, # Topic name
    .extendedInfo.ExtendedConsumerProperties.concurrency,
    .extendedInfo.ExtendedConsumerProperties.maxAttempts,
    .extendedInfo.ExtendedConsumerProperties.backOffInitialInterval,
    .extendedInfo.ExtendedConsumerProperties.backOffMaxInterval,
    .extendedInfo.ExtendedConsumerProperties.backOffMultiplier,
    .extendedInfo.ExtendedConsumerProperties.extension.enableDlq,
    (.extendedInfo.ExtendedConsumerProperties.extension.dlqName // ""), # Handle potential null
    (.extendedInfo.ExtendedConsumerProperties.extension.configuration."max.poll.interval.ms" // ""), # Handle missing/null, note quotes for key
    (.extendedInfo.ExtendedConsumerProperties.extension.configuration."max.poll.records" // "")  # Handle missing/null, note quotes for key
] | @csv
'