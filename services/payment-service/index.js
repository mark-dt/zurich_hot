const express = require("express");
const http = require("http");

const app = express();
const PORT = process.env.PORT || 3002;
const NOTIFICATION_SERVICE = process.env.NOTIFICATION_SERVICE_URL || "http://notification-service.workshop.svc.cluster.local:3004";
const FAILURE_RATE = parseFloat(process.env.FAILURE_RATE || "0");

function fetch(url) {
  return new Promise((resolve, reject) => {
    http.get(url, (res) => {
      let data = "";
      res.on("data", (chunk) => (data += chunk));
      res.on("end", () => resolve({ status: res.statusCode, data }));
    }).on("error", reject);
  });
}

function simulateLatency() {
  const base = 50 + Math.random() * 150; // 50-200ms normal
  return new Promise((resolve) => setTimeout(resolve, base));
}

function simulateFailureLatency() {
  const delay = 2000 + Math.random() * 6000; // 2-8s on failure
  return new Promise((resolve) => setTimeout(resolve, delay));
}

app.get("/health", (req, res) => {
  res.json({ service: "payment-service", status: "ok", failureRate: FAILURE_RATE });
});

app.get("/pay", async (req, res) => {
  const start = Date.now();
  const { orderId, amount } = req.query;

  // Simulate failure based on FAILURE_RATE
  if (Math.random() < FAILURE_RATE) {
    await simulateFailureLatency();
    const duration = Date.now() - start;
    console.log(JSON.stringify({ service: "payment-service", path: "/pay", orderId, status: 500, error: "payment processing failed", duration }));
    return res.status(500).json({ error: "payment processing failed", orderId });
  }

  await simulateLatency();

  // Notify on successful payment
  try {
    await fetch(`${NOTIFICATION_SERVICE}/notify?orderId=${orderId}&event=payment_confirmed`);
  } catch (err) {
    console.log(JSON.stringify({ service: "payment-service", path: "/pay", notification_error: err.message }));
  }

  const duration = Date.now() - start;
  console.log(JSON.stringify({ service: "payment-service", path: "/pay", orderId, amount, status: 200, duration }));
  res.json({ orderId, amount, paymentStatus: "confirmed", transactionId: `TXN-${Date.now()}` });
});

app.listen(PORT, () => console.log(`payment-service listening on :${PORT} (FAILURE_RATE=${FAILURE_RATE})`));
