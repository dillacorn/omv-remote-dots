import os
from mitmproxy.tools.main import mitmdump


def main():
    mitmdump(args=[
        "-s", "addon.py",
        "--mode", "regular",
        "--listen-host", "0.0.0.0",
        "--listen-port", os.environ.get("ARACHNIDIUM_PROXY_PORT", "8080"),
        "--set", "http3=false",
    ])


if __name__ == "__main__":
    main()
