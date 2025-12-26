import subprocess
import json
import sys

def get_smart_data(device_path):
    """
    Executes smartctl on a specific device and returns the JSON output.
    """
    try:
        # -a: all SMART info, -j: JSON format
        result = subprocess.run(
            ['sudo', 'smartctl', '-a', '-j', device_path],
            capture_output=True,
            text=True,
            check=False # smartctl returns non-zero bits for various warnings
        )
        return json.loads(result.stdout)
    except Exception as e:
        return {"error": f"Failed to read {device_path}: {str(e)}"}

def main():
    # Define the drives you want to check
    # You could also automate this using 'smartctl --scan --json'
    drives = ['/dev/sda', '/dev/nvme0n1']
    
    all_stats = {}

    for drive in drives:
        print(f"Fetching data for {drive}...", file=sys.stderr)
        all_stats[drive] = get_smart_data(drive)

    # Print the final aggregated JSON to stdout
    print(json.dumps(all_stats, indent=4))

if __name__ == "__main__":
    main()
