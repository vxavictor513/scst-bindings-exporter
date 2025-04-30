#!/bin/bash

# --- Configuration ---
NAMESPACE=""
REQUEST_TIMEOUT=5 # Timeout for curl/wget inside the pod
ACTUATOR_URL="http://localhost:8080/actuator/bindings"
OUTPUT_FILE=""
PARALLEL_PROCS=10
KUBECTL_EXEC_TIMEOUT="10s" # Timeout for the kubectl exec command itself
# --- End Configuration ---

# --- Helper Functions ---
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color
LOG_LEVEL=1 # 0=debug, 1=info, 2=warn, 3=error

# Check if terminal supports colors
if [ -t 2 ] && [ -z "${NO_COLOR}" ] && [ "${TERM}" != "dumb" ]; then
    USE_COLORS=1
else
    USE_COLORS=0
fi

# Use printf for better portability than echo -e
log_debug() { if [ $LOG_LEVEL -le 0 ]; then if [ $USE_COLORS -eq 1 ]; then printf "${NC}[DEBUG]${NC} %s\n" "$1" >&2; else printf "[DEBUG] %s\n" "$1" >&2; fi; fi; }
log_info()  { if [ $LOG_LEVEL -le 1 ]; then if [ $USE_COLORS -eq 1 ]; then printf "${GREEN}[INFO]${NC} %s\n" "$1" >&2; else printf "[INFO] %s\n" "$1" >&2; fi; fi; }
log_warn()  { if [ $LOG_LEVEL -le 2 ]; then if [ $USE_COLORS -eq 1 ]; then printf "${YELLOW}[WARN]${NC} %s\n" "$1" >&2; else printf "[WARN] %s\n" "$1" >&2; fi; fi; }
log_error() { if [ $USE_COLORS -eq 1 ]; then printf "${RED}[ERROR]${NC} %s\n" "$1" >&2; else printf "[ERROR] %s\n" "$1" >&2; fi; exit 1; }

usage() {
    printf "Usage: %s -n <namespace> [-o <output_file>] [-c] [-p <parallel_procs>] [-q] [-v] <deployment_name1> [<deployment_name2> ...]\n" "$0" >&2
    printf "  -n <namespace>     : Kubernetes namespace (required)\n" >&2
    printf "  -o <output_file>   : Output file (optional, default: bindings_YYYY-MM-DD_HHMMSS.json)\n" >&2
    printf "  -c                 : Disable colored output\n" >&2
    printf "  -p <parallel_procs>: Number of parallel processes (default: %s)\n" "$PARALLEL_PROCS" >&2
    printf "  -q                 : Quiet mode (show only warnings/errors, overrides -v)\n" >&2
    printf "  -v                 : Verbose mode (debug output)\n" >&2
    exit 1
}
# --- End Helper Functions ---

# --- Dependency Check ---
if ! command -v kubectl >/dev/null 2>&1; then log_error "kubectl command not found. Please install kubectl."; fi
if ! command -v jq >/dev/null 2>&1; then log_error "jq command not found. Please install jq."; fi
if ! command -v mktemp >/dev/null 2>&1; then log_error "mktemp command not found. Cannot create temporary directory."; fi
# --- End Dependency Check ---

# --- Argument Parsing ---
while getopts ":n:o:cp:qv" opt; do
  case ${opt} in
    n ) NAMESPACE=$OPTARG ;;
    o ) OUTPUT_FILE=$OPTARG ;;
    c ) USE_COLORS=0 ;;
    p ) PARALLEL_PROCS=$OPTARG ;;
    q ) LOG_LEVEL=2 ;;
    v ) if [ "$LOG_LEVEL" -ge 1 ]; then LOG_LEVEL=0; fi ;;
    \? ) log_error "Invalid option: -$OPTARG"; usage ;;
    : ) log_error "Option -$OPTARG requires an argument."; usage ;;
  esac
done
shift $((OPTIND -1))

if [ -z "$NAMESPACE" ]; then log_error "Namespace must be specified using -n <namespace>"; usage; fi
# Portable check for positive integer
case "$PARALLEL_PROCS" in
    ''|*[!0-9]*) log_error "Parallel processes (-p) must be a positive integer: '$PARALLEL_PROCS'"; usage ;;
    0*) log_error "Parallel processes (-p) must be a positive integer: '$PARALLEL_PROCS'"; usage ;;
    *) ;;
esac
if [ $# -eq 0 ]; then log_error "No deployment names provided."; usage; fi

if [ -z "$OUTPUT_FILE" ]; then
    TIMESTAMP=$(date +"%Y-%m-%d_%H%M%S")
    OUTPUT_FILE="bindings_${TIMESTAMP}.json"
    log_info "Output will be saved to: $OUTPUT_FILE"
fi

DEPLOYMENT_NAMES=("$@")
log_debug "Deployments to process: ${DEPLOYMENT_NAMES[@]}"
# --- End Argument Parsing ---

# --- Main Logic ---
log_info "Processing deployments in namespace: $NAMESPACE with up to $PARALLEL_PROCS parallel jobs"

TEMP_DIR=$(mktemp -d)
if [ -z "$TEMP_DIR" ] || [ ! -d "$TEMP_DIR" ]; then
    log_error "Failed to create temporary directory."
fi
log_debug "Using temporary directory: $TEMP_DIR"
RESULTS_FILE="$TEMP_DIR/results.txt"

# Cleanup temporary directory on exit
trap 'rm -rf "$TEMP_DIR"' EXIT INT TERM

# Initialize results tracking file header
if ! touch "$RESULTS_FILE" 2>/dev/null; then
     log_error "Cannot write to temporary results file: $RESULTS_FILE"
fi
echo "DEPLOYMENT|STATUS|MESSAGE" > "$RESULTS_FILE"

# Function to process a single deployment (runs in background)
process_deployment() {
    local deployment_name=$1
    # Relies on TEMP_DIR being inherited correctly by background process
    local result_file="$TEMP_DIR/${deployment_name}.json"
    local status_message=""
    local deployment_json selector pod_name fetch_command exec_output bindings_output binding_count exit_status jq_cmd

    # Diagnostic check - remove if background inheritance is confirmed stable
    # if [ ! -d "$TEMP_DIR" ]; then
    #    log_error "INTERNAL ERROR: TEMP_DIR '$TEMP_DIR' not accessible in process_deployment for $deployment_name"
    #    echo "$deployment_name|ERROR|Temp dir not accessible" >&2 ; return 1
    # fi

    deployment_json=$(kubectl get deployment "$deployment_name" -n "$NAMESPACE" -o json 2>&1)
    if ! kubectl_exit_code=$?; [ $kubectl_exit_code -eq 0 ]; then
        : # Continue on success
    else
        status_message="Failed to get deployment: ${deployment_json%%$'\n'*}"
        log_warn "Failed to get deployment '$deployment_name'. Error: $status_message. Skipping."
        printf "%s|ERROR|%s\n" "$deployment_name" "$status_message" >> "$RESULTS_FILE"
        return 1
    fi

    # Extract selector (.spec.selector.matchLabels first)
    jq_cmd='.spec.selector.matchLabels | to_entries | map("\(.key)=\(.value)") | join(",")'
    selector=$(echo "$deployment_json" | jq -r "$jq_cmd" 2>/dev/null)
    if [ -z "$selector" ] || [ "$selector" = "null" ]; then
        # Fallback to older .spec.selector (less common)
        jq_cmd='.spec.selector | to_entries | map("\(.key)=\(.value)") | join(",")'
        selector=$(echo "$deployment_json" | jq -r "$jq_cmd" 2>/dev/null)
        if [ -z "$selector" ] || [ "$selector" = "null" ]; then
            status_message="Could not extract selector"
            log_warn "Could not extract selector for deployment '$deployment_name'. Skipping."
            printf "%s|ERROR|%s\n" "$deployment_name" "$status_message" >> "$RESULTS_FILE"
            return 1
        fi
    fi

    # Find a running pod (Prefer Ready, fallback to just Running)
    pod_name=$(kubectl get pods -n "$NAMESPACE" -l "$selector" \
        --field-selector=status.phase=Running \
        -o jsonpath='{.items[?(@.status.containerStatuses[*].ready==true)].metadata.name}' 2>/dev/null | awk '{print $1}')

    if [ -z "$pod_name" ]; then
        pod_name=$(kubectl get pods -n "$NAMESPACE" -l "$selector" --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
        if [ -z "$pod_name" ]; then
            status_message="No running pods found"
            log_warn "No running pods found for deployment '$deployment_name'. Skipping."
            printf "%s|ERROR|%s\n" "$deployment_name" "$status_message" >> "$RESULTS_FILE"
            return 1
        fi
    fi

    # Define command to fetch bindings from inside the pod
    # Uses exported REQUEST_TIMEOUT and ACTUATOR_URL
    fetch_command=$(cat <<EOF
if command -v curl &>/dev/null; then
    if command -v timeout &>/dev/null; then timeout ${REQUEST_TIMEOUT} curl -s --fail "${ACTUATOR_URL}"; else curl -s --fail "${ACTUATOR_URL}"; fi
elif command -v wget &>/dev/null; then
    if command -v timeout &>/dev/null; then timeout ${REQUEST_TIMEOUT} wget -qO- "${ACTUATOR_URL}"; else wget -qO- "${ACTUATOR_URL}"; fi
else
    echo "Error: Neither curl nor wget are available in this container" >&2; exit 6
fi
EOF
)

    # Execute command in pod
    exec_output=$(kubectl exec -n "$NAMESPACE" "$pod_name" --request-timeout="$KUBECTL_EXEC_TIMEOUT" -- /bin/sh -c "$fetch_command" 2>&1)
    exit_status=$?

    # Handle command execution errors
    if [ $exit_status -ne 0 ]; then
        # Prioritize specific known errors
        if echo "$exec_output" | grep -q "Neither curl nor wget are available"; then status_message="Pod fetch: No curl/wget";
        elif [ $exit_status -eq 124 ]; then status_message="Pod fetch: Command timed out ($REQUEST_TIMEOUT s)";
        elif [ $exit_status -eq 22 ]; then status_message="Pod fetch: HTTP error >= 400 (curl)";
        elif [ $exit_status -eq 8 ]; then status_message="Pod fetch: Server error response (wget)";
        elif [ $exit_status -eq 6 ]; then status_message="Pod fetch: Hostname resolution failed (curl/wget)";
        elif echo "$exec_output" | grep -q "unable to upgrade connection"; then status_message="Kubectl exec: Network issue to kubelet"
        else status_message="Pod fetch: Command failed (${exec_output:0:40}...)"; fi # Generic fallback

        log_warn "Command failed for '$deployment_name'. Status: $status_message (Exit code: $exit_status)"
        printf "%s|ERROR|%s\n" "$deployment_name" "$status_message" >> "$RESULTS_FILE"
        return 1
    fi

    # Handle empty successful response
    bindings_output="$exec_output"
    if [ -z "$bindings_output" ]; then
        log_debug "Empty response received from pod '$pod_name'. Treating as empty JSON array."
        bindings_output="[]"
    fi

    # Validate JSON and write results
    if echo "$bindings_output" | jq -e . > /dev/null 2>&1; then
        # Write individual JSON result file
        if ! jq -n --arg ns "$NAMESPACE" --arg dep "$deployment_name" --arg pod "$pod_name" --argjson bindings "$bindings_output" \
              '{namespace: $ns, deployment: $dep, pod: $pod, bindings: $bindings}' > "$result_file"; then
             status_message="Failed to create JSON fragment file ($result_file)"
             log_warn "jq failed to create JSON fragment for '$deployment_name'. Skipping write."
             # Record success in summary, but note the file issue
             printf "%s|SUCCESS|Retrieved bindings (JSON file write failed)\n" "$deployment_name" >> "$RESULTS_FILE"
             return 0 # Proceed, but combined output file will miss this entry
        fi

        binding_count=$(echo "$bindings_output" | jq '. | length' 2>/dev/null) # Suppress jq errors here
        if [ "$binding_count" = "null" ] || ! [[ "$binding_count" =~ ^[0-9]+$ ]]; then # Check if null or not a number
             binding_count=0
             log_debug "Could not determine binding count from JSON for '$deployment_name', assuming 0."
        fi

        printf "%s|SUCCESS|Retrieved %s bindings\n" "$deployment_name" "$binding_count" >> "$RESULTS_FILE"
        return 0
    else
        status_message="Pod fetch: Non-JSON response"
        log_warn "Non-JSON response received from pod '$pod_name' ($deployment_name). Snippet: $(echo "$bindings_output" | head -c 100)..."
        printf "%s|ERROR|%s\n" "$deployment_name" "$status_message" >> "$RESULTS_FILE"
        return 1
    fi
}

# Export variables needed by the backgrounded function
# Crucially export TEMP_DIR and RESULTS_FILE so background jobs can find them
export NAMESPACE ACTUATOR_URL REQUEST_TIMEOUT KUBECTL_EXEC_TIMEOUT USE_COLORS TEMP_DIR RESULTS_FILE LOG_LEVEL
export -f process_deployment

# Parallel processing using background jobs
log_info "Using background processes for parallelism (Max: $PARALLEL_PROCS)"
for deployment_name in "${DEPLOYMENT_NAMES[@]}"; do
    process_deployment "$deployment_name" &
    # Limit concurrent jobs using portable 'jobs -p | grep -c .'
    while [ "$(jobs -p | grep -c .)" -ge "$PARALLEL_PROCS" ]; do
        sleep 0.1
    done
done
log_debug "Waiting for background jobs to complete..."
wait # Wait for all background jobs
log_debug "All background jobs finished."


# --- Output ---
# Aggregate individual JSON results into the final output file
log_info "Aggregating results into $OUTPUT_FILE..."

# Check TEMP_DIR existence before find
if [ ! -d "$TEMP_DIR" ]; then
   log_warn "Temporary directory '$TEMP_DIR' not found after processing. Cannot aggregate JSON."
   echo "[]" > "$OUTPUT_FILE"
else
    # Use find ... -print0 | xargs -0 for safety with special filenames
    # Check if any .json files exist before running jq
    json_files_found=0
    if find "$TEMP_DIR" -maxdepth 1 -name "*.json" -print -quit | grep -q .; then
        json_files_found=1
    fi

    if [ "$json_files_found" -eq 1 ]; then
        find "$TEMP_DIR" -maxdepth 1 -name "*.json" -print0 | xargs -0 --no-run-if-empty jq -s '.' > "$OUTPUT_FILE"
        jq_exit_code=$?

        if [ $jq_exit_code -ne 0 ]; then
            log_warn "Failed to combine JSON results (jq exit code: $jq_exit_code). Output file might be incomplete or invalid: $OUTPUT_FILE"
        elif ! [ -s "$OUTPUT_FILE" ]; then
             log_warn "Aggregated output file is empty, likely no JSON fragments were found/readable in $TEMP_DIR."
             echo "[]" > "$OUTPUT_FILE" # Output empty array
        else
             log_debug "Successfully aggregated JSON fragments."
        fi
    else
        log_warn "No individual JSON result files were found in $TEMP_DIR."
        echo "[]" > "$OUTPUT_FILE" # Output empty array if no results found
    fi
fi


# --- Summary Report ---
echo # Add a newline for spacing
echo "----------------------------------------"
echo "SUMMARY REPORT"
echo "----------------------------------------"
echo "Namespace: $NAMESPACE"
echo "Output file: $OUTPUT_FILE"
echo

# Check if results file exists before processing summary
if [ ! -f "$RESULTS_FILE" ]; then
    log_warn "Results file '$RESULTS_FILE' not found. Cannot generate summary."
    echo "Total Processed: 0 | Success: 0 | Error: 0"
    echo "----------------------------------------"
    exit 1
fi

# Calculate column widths dynamically for cleaner output
max_name_len=10 # Minimum width
header_pattern='^DEPLOYMENT\|STATUS\|MESSAGE$'

# Use process substitution to avoid subshell variable scope issues for max_name_len
while IFS="|" read -r dep _ _; do
    if [ -z "$dep" ]; then continue; fi
    current_len=${#dep}
    if [ "$current_len" -gt "$max_name_len" ]; then max_name_len=$current_len; fi
done < <(cut -d'|' -f1 "$RESULTS_FILE" | grep -v "$header_pattern")

deployment_width=$((max_name_len + 2)) # Add padding
status_width=9 # Fixed width for "STATUS" + padding

# Print the table header
printf "%-${deployment_width}s | %-${status_width}s | %s\n" "DEPLOYMENT" "STATUS" "MESSAGE"
# Print separator line using portable printf/tr
printf "%s|%s|%s\n" "$(printf '%*s' "$deployment_width" '' | tr ' ' '-')" \
                     "$(printf '%*s' "$status_width" '' | tr ' ' '-')" \
                     "$(printf '%*s' 50 '' | tr ' ' '-')"

success_count=0
error_count=0

# Read sorted results using Process Substitution to keep counts in scope
while IFS="|" read -r deployment status message || [ -n "$deployment" ]; do # Handle last line without newline
    # Trim whitespace using portable parameter expansion
    deployment="${deployment#"${deployment%%[![:space:]]*}"}"; deployment="${deployment%"${deployment##*[![:space:]]}"}"
    status="${status#"${status%%[![:space:]]*}"}"; status="${status%"${status##*[![:space:]]}"}"
    message="${message#"${message%%[![:space:]]*}"}"; message="${message%"${message##*[![:space:]]}"}"

    if [ -z "$deployment" ]; then continue; fi # Skip empty lines

    # Truncate long messages for display
    if [ ${#message} -gt 50 ]; then message="${message:0:47}..."; fi

    # Colorize status and count results
    colored_status="$status"
    if [ "$status" = "SUCCESS" ]; then
        success_count=$((success_count + 1))
        if [ $USE_COLORS -eq 1 ]; then colored_status="${GREEN}${status}${NC}"; fi
    elif [ "$status" = "ERROR" ]; then
         error_count=$((error_count + 1))
         if [ $USE_COLORS -eq 1 ]; then colored_status="${RED}${status}${NC}"; fi
    # Handle specific "write failed" status as warning/success
    elif echo "$status" | grep -q "(JSON file write failed)"; then
         success_count=$((success_count + 1)) # Count as success overall
         if [ $USE_COLORS -eq 1 ]; then colored_status="${YELLOW}${status}${NC}"; fi
    else
        log_debug "Unknown status '$status' for deployment '$deployment', counting as error."
        error_count=$((error_count + 1))
        if [ $USE_COLORS -eq 1 ]; then colored_status="${YELLOW}${status}${NC}"; fi # Yellow for unknown
    fi

    # Print the formatted row, manually padding colored status
    if [ $USE_COLORS -eq 1 ] && { [ "$status" = "SUCCESS" ] || [ "$status" = "ERROR" ] || echo "$status" | grep -q "(JSON file write failed)" || [ "$status" = "UNKNOWN" ] ; }; then
        visible_len=${#status} # Estimate length of visible text
        padding_len=$((status_width - visible_len))
        [ $padding_len -lt 0 ] && padding_len=0 # Prevent negative padding
        # Use %b with printf to interpret color escape codes
        padded_colored_status=$(printf "%b%*s" "$colored_status" "$padding_len" "")
        printf "%-${deployment_width}s | %s | %s\n" "$deployment" "$padded_colored_status" "$message"
    else
        printf "%-${deployment_width}s | %-${status_width}s | %s\n" "$deployment" "$status" "$message"
    fi

done < <(sort -t'|' -k1 "$RESULTS_FILE" | grep -v "$header_pattern") # Feed loop from sorted, filtered file

# Print final statistics
total_count=$((success_count + error_count))
echo
echo "----------------------------------------"
echo "Total Processed: $total_count | Success: $success_count | Error: $error_count"
echo "----------------------------------------"

log_info "Results aggregation saved to $OUTPUT_FILE"

# Exit with non-zero status if there were errors
if [ "$error_count" -gt 0 ]; then
    log_warn "Processing finished with $error_count error(s)."
    exit 1
else
    log_info "Processing finished successfully."
    exit 0
fi