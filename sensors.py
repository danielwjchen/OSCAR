import psutil
import json
import time

def get_temperatures():
    """
    Retrieves hardware temperatures and returns them as a dictionary.
    """
    temps_data = {}
    
    # psutil.sensors_temperatures() returns a dict of lists
    try:
        raw_temps = psutil.sensors_temperatures()
        
        for name, entries in raw_temps.items():
            temps_data[name] = []
            for entry in entries:
                temps_data[name].append({
                    "label": entry.label or name,
                    "current": entry.current,
                    "high": entry.high,
                    "critical": entry.critical
                })
    except AttributeError:
        return {"error": "Temperature sensors not detected or supported on this system."}

    return temps_data

def get_system_stats():
    # 1. CPU Usage (per core and total percentage)
    # interval=1 is recommended for an accurate reading
    cpu_percent = psutil.cpu_percent(interval=1)
    cpu_cores = psutil.cpu_percent(interval=None, percpu=True)

    # 2. Memory Usage
    mem = psutil.virtual_memory()
    memory_stats = {
        "total_gb": round(mem.total / (1024**3), 2),
        "available_gb": round(mem.available / (1024**3), 2),
        "used_percent": mem.percent
    }

    # 3. Network Usage (Total bytes sent/received)
    net = psutil.net_io_counters()
    network_stats = {
        "bytes_sent": net.bytes_sent,
        "bytes_recv": net.bytes_recv,
        "packets_sent": net.packets_sent,
        "packets_recv": net.packets_recv
    }

    return {
        "cpu": {
            "total_percent": cpu_percent,
            "per_core": cpu_cores
        },
        "memory": memory_stats,
        "network": network_stats
    }

if __name__ == "__main__":
    stats = get_system_stats()
    print(json.dumps(stats, indent=4))

    data = get_temperatures()
    # Output as formatted JSON
    print(json.dumps(data, indent=4))
