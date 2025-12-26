import socket
import json
import urllib.request

def get_ip_report():
    report = {}

    # 1. Get Local IP Address
    try:
        # We connect to a dummy address to see which interface the OS prefers
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        report["local_ip"] = s.getsockname()[0]
        s.close()
    except Exception:
        report["local_ip"] = "127.0.0.1"

    # 2. Get Public IP Address
    try:
        # Using a simple text-based API
        public_ip = urllib.request.urlopen('https://ident.me').read().decode('utf8')
        report["public_ip"] = public_ip
    except Exception as e:
        report["public_ip"] = f"Error: {str(e)}"

    return report

if __name__ == "__main__":
    print(json.dumps(get_ip_report(), indent=4))
