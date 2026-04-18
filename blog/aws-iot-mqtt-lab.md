
*Hands-on lab with AWS IoT Core, MQTT messaging, and SNS integration*

---

## Prerequisites

Before starting this lab, ensure you have:

- AWS Account with admin access
- All resources will be created in **us-west-2**
- AWS CloudShell access

---

## Task 1: Create IoT Policy, Thing, and Publisher

### 1.1 Create IoT Policy

1. Navigate to the **AWS IoT Core** service.
2. In the left menu, open **Security → Policies** and click **Create policy**.
3. Choose the **JSON** editor and paste this policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "iot:*",
      "Resource": "*"
    }
  ]
}
```

4. Click **Create**.

### 1.2 Create IoT Thing with Certificate

1. In the left menu, open **All devices → Things** and click **Create things**.
2. Select **Create single thing → Next**.
3. Configure the thing:
    - **Thing name:** `MySensor`
    - Leave other settings as default.
4. Choose **Auto-generate a new certificate** and continue with **Next**.
5. On the **Attach policies** step, check **IoTPolicy** and choose **Create thing**.
6. Download the certificates (this is the only chance):
    - Device certificate (`-certificate.pem.crt`)
    - Private key (`-private.pem.key`)
    - Amazon Root CA 1 (recommended)
7. Click **Done**.

### 1.3 Get IoT Endpoint

1. In the IoT Core console, open **Settings**.
2. Copy the **Device data endpoint** (looks like `xxxxx-ats.iot.us-west-2.amazonaws.com`).
3. Save the endpoint—you will reuse it throughout the lab.

### 1.4 Set Up Publisher in CloudShell

1. Open **CloudShell** from the AWS Console.
2. Create and activate a Python virtual environment:

```bash
python3 -m venv .venv
source .venv/bin/activate
```

3. Install the AWS IoT Device SDK for Python v2:

```bash
git clone https://github.com/aws/aws-iot-device-sdk-python-v2.git
pip install ./aws-iot-device-sdk-python-v2
```

4. Create `publisher.py` and paste the code below:

```python
# Minimal MQTT5 publisher (mTLS)
from awsiot import mqtt5_client_builder
from awscrt import mqtt5
import argparse, time, uuid, threading, json

p = argparse.ArgumentParser()
p.add_argument("--endpoint", required=True)
p.add_argument("--cert", required=True)
p.add_argument("--key", required=True)
p.add_argument("--ca_file", default=None)
p.add_argument("--topic", default="demo/topic")
p.add_argument("--message", default="Hello from mqtt5 publisher")
p.add_argument("--count", type=int, default=5)
p.add_argument("--client_id", default=f"mqtt5-pub-{uuid.uuid4().hex[:8]}")
a = p.parse_args()

connected = threading.Event()


def on_conn_ok(_):
    connected.set()


client = mqtt5_client_builder.mtls_from_path(
    endpoint=a.endpoint,
    cert_filepath=a.cert,
    pri_key_filepath=a.key,
    ca_filepath=a.ca_file,
    client_id=a.client_id,
    on_lifecycle_connection_success=on_conn_ok,
)

client.start()
if not connected.wait(30):
    raise TimeoutError("Connection timeout")

for i in range(1, (a.count if a.count > 0 else 1_000_000) + 1):
    payload = {
        "message": a.message,
        "count": i,
        "timestamp": time.time(),
    }
    payload_json = json.dumps(payload)
    print(f"Publishing to '{a.topic}': {payload_json}")
    fut = client.publish(
        mqtt5.PublishPacket(
            topic=a.topic,
            payload=payload_json.encode("utf-8"),
            qos=mqtt5.QoS.AT_LEAST_ONCE,
        )
    )
    fut.result(30)
    time.sleep(1.0)

client.stop()
print("Done.")
```

5. Upload your certificates to CloudShell:
    - Click **Actions → Upload file** and upload `*-certificate.pem.crt`.
    - Upload `*-private.pem.key` the same way.

6. Run the publisher (replace placeholders with your values):

```bash
python publisher.py \
  --endpoint YOUR-ENDPOINT-ats.iot.us-west-2.amazonaws.com \
  --cert YOUR-CERT-certificate.pem.crt \
  --key YOUR-KEY-private.pem.key
```

### 1.5 Verify Messages in MQTT Test Client

1. In the IoT console, open **MQTT test client**.
2. Choose **Subscribe to a topic**.
3. Set **Topic filter** to `demo/topic` and click **Subscribe**.
4. **Expected Result:**
    - JSON messages appear with `count`, `message`, and `timestamp` fields.

---

## Task 2: Create MQTT Subscriber

### 2.1 Open New CloudShell Tab

1. In CloudShell, click the **+** icon to open a second tab.
2. Reactivate the virtual environment:

```bash
source .venv/bin/activate
```

### 2.2 Create Subscriber Script

1. Create `subscriber.py` and paste the code below:

```python
# Minimal MQTT5 subscriber (mTLS)
from awsiot import mqtt5_client_builder
from awscrt import mqtt5
import argparse, uuid, threading

p = argparse.ArgumentParser()
p.add_argument("--endpoint", required=True)
p.add_argument("--cert", required=True)
p.add_argument("--key", required=True)
p.add_argument("--ca_file", default=None)
p.add_argument("--topic", default="demo/topic")
p.add_argument("--client_id", default=f"mqtt5-sub-{uuid.uuid4().hex[:8]}")
a = p.parse_args()

connected = threading.Event()


def on_conn_ok(_):
    connected.set()
    print("Connected to AWS IoT Core")


def on_message(data):
    try:
        packet = data.publish_packet
        payload = packet.payload.decode("utf-8")
        print(f"\n[Received from '{packet.topic}']")
        print(payload)
        print("-" * 50)
    except Exception as err:
        print(f"Error decoding message: {err}")


client = mqtt5_client_builder.mtls_from_path(
    endpoint=a.endpoint,
    cert_filepath=a.cert,
    pri_key_filepath=a.key,
    ca_filepath=a.ca_file,
    client_id=a.client_id,
    on_lifecycle_connection_success=on_conn_ok,
    on_publish_received=on_message,
)

print(f"Starting subscriber with client_id: {a.client_id}")
client.start()

if not connected.wait(30):
    raise TimeoutError("Connection timeout")

print(f"Subscribing to topic: {a.topic}")
subscription = mqtt5.SubscribePacket(
    subscriptions=[
        mqtt5.Subscription(topic_filter=a.topic, qos=mqtt5.QoS.AT_LEAST_ONCE)
    ]
)
client.subscribe(subscription).result(30)
print(f"Successfully subscribed to '{a.topic}'")
print("Waiting for messages... (Press Ctrl+C to exit)")

try:
    threading.Event().wait()
except KeyboardInterrupt:
    print("\nShutting down...")
    client.stop()
    print("Done.")
```

### 2.3 Run Subscriber

1. Run the subscriber (replace placeholders with your values):

```bash
python subscriber.py \
  --endpoint YOUR-ENDPOINT-ats.iot.us-west-2.amazonaws.com \
  --cert YOUR-CERT-certificate.pem.crt \
  --key YOUR-KEY-private.pem.key \
  --topic demo/topic
```

2. **Expected Output:**
    - "Connected to AWS IoT Core"
    - "Successfully subscribed to 'demo/topic'"
    - "Waiting for messages..."

### 2.4 Test Publisher and Subscriber Together

1. Switch back to the first CloudShell tab (publisher).
2. Run the publisher again:

```bash
python publisher.py \
  --endpoint YOUR-ENDPOINT-ats.iot.us-west-2.amazonaws.com \
  --cert YOUR-CERT-certificate.pem.crt \
  --key YOUR-KEY-private.pem.key
```

3. Return to the subscriber tab.
4. **Expected Result:**
    - Subscriber displays each published message in real time.

---

## Task 3: Route Messages to SNS via IoT Rule

### 3.1 Create IAM Role for IoT

1. Navigate to the **IAM** service.
2. Select **Roles → Create role**.
3. Configure the trusted entity:
    - **AWS service** → **IoT** use case → **IoT**.
4. Add permissions:
    - Search for and select `AmazonSNSFullAccess`.
5. Name the role `IoTtoSNSRole` and click **Create role**.

### 3.2 Create SNS Topic and Email Subscription

1. Open the **Amazon SNS** service.
2. In the left menu, select **Topics → Create topic**.
3. Configuration:
    - **Type:** Standard
    - **Name:** `IoTMessages`
4. Click **Create topic**.
5. Create a subscription:
    - Click **Create subscription**.
    - **Protocol:** Email
    - **Endpoint:** Your email address
    - Click **Create subscription** and confirm the email.

### 3.3 Create IoT Rule

1. Return to **AWS IoT Core**.
2. Select **Message routing → Rules → Create rule**.
3. Configure the rule properties:
    - **Rule name:** `DemoTopicToSNS`
    - **Description:** `Route messages to SNS`
4. SQL statement:

```sql
SELECT * FROM 'demo/topic' WHERE count > 4
```

5. Add an action:
    - Choose **Simple Notification Service (SNS)**.
    - Set **SNS topic** to `IoTMessages`.
    - **Message format:** RAW
    - **IAM role:** `IoTtoSNSRole`
6. (Optional) Add an error action using the same topic and role.
7. Review and click **Create**.

### 3.4 Test End-to-End

1. In CloudShell, run the publisher with additional messages:

```bash
python publisher.py \
  --endpoint YOUR-ENDPOINT-ats.iot.us-west-2.amazonaws.com \
  --cert YOUR-CERT-certificate.pem.crt \
  --key YOUR-KEY-private.pem.key \
  --count 10
```

2. **Expected Results:**
    - Messages with `count` greater than 4 trigger the IoT rule.
    - SNS sends email notifications for those messages.
    - Check your inbox and confirm the alerts arrive.

---

## Testing Summary

- ✅ **Task 1:** MQTT publisher running and messages visible in the MQTT test client
- ✅ **Task 2:** Subscriber receives messages in CloudShell
- ✅ **Task 3:** IoT Rule forwards filtered messages to Amazon SNS

---

## Clean Up (Optional)

### IoT Core

- Delete the **Thing** `MySensor`.
- Delete the **Policy** `IoTPolicy`.
- Delete the **Rule** `DemoTopicToSNS`.

### SNS

- Delete the topic `IoTMessages`.

### IAM

- Delete the role `IoTtoSNSRole`.

### CloudShell

- Files in CloudShell are ephemeral and will be cleaned up automatically.

---

## Troubleshooting

### Publisher/Subscriber Connection Issues

- Verify the endpoint from **IoT Core → Settings**.
- Confirm certificate filenames match exactly.
- Ensure certificates reside in the same directory as the scripts.
- Check that `IoTPolicy` is attached to the Thing's certificate.

### Not Receiving SNS Emails

- Confirm your email subscription by clicking the verification link.
- Make sure the IoT rule SQL filters (`count > 4`) are satisfied.
- Run the publisher with `--count 10` to generate matches.

### Python SDK Errors

- Ensure the virtual environment is active: `source .venv/bin/activate`.
- Reinstall the SDK if needed: `pip install ./aws-iot-device-sdk-python-v2`.

---

**Lab Complete! You've successfully:**

- Secured an IoT Thing with policies and certificates
- Published and subscribed to MQTT messages over mTLS
- Routed IoT data to Amazon SNS using IoT Rules


