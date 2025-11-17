# 1) create the test file
cat > test_ws.py <<'PY'
# test_ws.py
import sys, ssl
from websocket import create_connection, WebSocketException

if len(sys.argv) < 4:
    print("Usage: python3 test_ws.py <ip> <port> <ws|wss>")
    sys.exit(1)

ip = sys.argv[1]; port = int(sys.argv[2]); scheme = sys.argv[3].lower()
url = f"{scheme}://{ip}:{port}"
print("Trying:", url)
try:
    if scheme == "wss":
        ws = create_connection(url, sslopt={"cert_reqs": ssl.CERT_NONE})
    else:
        ws = create_connection(url)
    print("✅ Connected. Sending request…")
    ws.send('{"id":"ping","type":"request","uri":"ssap://system/getSystemInfo","payload":{}}')
    resp = ws.recv()
    print("⬅️ Received:", resp)
    ws.close()
except WebSocketException as e:
    print("WebSocketException:", e)
except Exception as e:
    print("Error:", type(e).__name__, e)
PY

# 2) ensure websocket-client is installed
pip3 install --user websocket-client

# 3) run tests (replace IP if different)
python3 test_ws.py 192.168.29.29 3000 ws
python3 test_ws.py 192.168.29.29 3001 wss

